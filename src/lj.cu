/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/


/*----------------------------------------------------------------------------80
The class dealing with the Lennard-Jones (LJ) pairwise potentials.
------------------------------------------------------------------------------*/

#include "lj.cuh"
#include "mic.cuh"
#include "measure.cuh"
#include "atom.cuh"
#include "error.cuh"

// best block size here: 128
#define BLOCK_SIZE_FORCE 128
#define GPU_FIND_FORCE(A, B, C)                                                \
    gpu_find_force<A, B, C>                                                    \
    <<<grid_size, BLOCK_SIZE_FORCE>>>                                          \
    (                                                                          \
        measure->hnemd.fe_x, measure->hnemd.fe_y, measure->hnemd.fe_z,         \
        lj_para, atom->N, N1, N2,atom->box.triclinic, atom->box.pbc_x,         \
        atom->box.pbc_y, atom->box.pbc_z, atom->NN_local, atom->NL_local,      \
        atom->type, shift, atom->x, atom->y, atom->z,                          \
        atom->vx, atom->vy, atom->vz,                                          \
        atom->box.h, atom->fx, atom->fy, atom->fz, atom->virial_per_atom,      \
        atom->potential_per_atom, atom->heat_per_atom, atom->group[0].label,   \
        measure->shc.fv_index, measure->shc.fv, measure->shc.a_map,            \
        measure->shc.b_map, measure->shc.count_b                               \
    )

LJ::LJ
(
        FILE *fid, int num_types,
        const std::vector<int> participating_kinds, int type_range
)
{
    printf("Use %d-element LJ potential.\n", num_types);
    if (!(num_types >= 1 && num_types <= MAX_TYPE))
    { print_error("Incorrect number of LJ parameters.\n"); exit(1);}

    double epsilon, sigma, cutoff;
    rc = 0.0;
    for (int n = 0; n < type_range; n++)
    {
        for (int m = 0; m < type_range; m++)
        {
            if (pair_participating(n,m,participating_kinds))
            {
                int count = fscanf(fid, "%lf%lf%lf", &epsilon, &sigma, &cutoff);
                if (count!=3)
                {print_error("reading error for potential file.\n");exit(1);}
                lj_para.s6e4[n][m]   = pow(sigma, 6.0)  * epsilon * 4.0;
                lj_para.s12e4[n][m]  = pow(sigma, 12.0) * epsilon * 4.0;
                lj_para.cutoff_square[n][m] = cutoff * cutoff;
                if (rc < cutoff) rc = cutoff;
            }
            else // pair not participating, but must still be defined
            {
                lj_para.s6e4[n][m]   = ONE;
                lj_para.s12e4[n][m]  = ONE;
                lj_para.cutoff_square[n][m] = ZERO;
            }
        }
    }
}

LJ::~LJ(void)
{
    // nothing
}

bool LJ::pair_participating
(
        int n, int m, const std::vector<int> participating_kinds
)
{
    bool m_part = false;
    bool n_part = false;
    for (int i = 0; i < (int)participating_kinds.size(); i++)
    {
        if (participating_kinds[i] == m) m_part = true;
        if (participating_kinds[i] == n) n_part = true;
        if (m_part && n_part) return true; // early exit
    }
    return false;
}

// get U_ij and (d U_ij / d r_ij) / r_ij (the LJ potential)
static __device__ void find_p2_and_f2
(real s6e4, real s12e4, real d12sq, real &p2, real &f2)
{
    real d12inv2 = ONE / d12sq;
    real d12inv6 = d12inv2 * d12inv2 * d12inv2;
    f2 = SIX * (s6e4 * d12inv6 - s12e4 * TWO * d12inv6 * d12inv6) * d12inv2;
    p2 = s12e4 * d12inv6 * d12inv6 - s6e4 * d12inv6;
}

// force evaluation kernel
template <int cal_j, int cal_q, int cal_k>
static __global__ void gpu_find_force
(
    real fe_x, real fe_y, real fe_z,
    LJ_Para lj,
    int number_of_particles, int N1, int N2,
    int triclinic, int pbc_x, int pbc_y, int pbc_z,
    int *g_neighbor_number, int *g_neighbor_list, int *g_type, int shift,
    const real* __restrict__ g_x,
    const real* __restrict__ g_y,
    const real* __restrict__ g_z,
    const real* __restrict__ g_vx,
    const real* __restrict__ g_vy,
    const real* __restrict__ g_vz,
    const real* __restrict__ g_box, real *g_fx, real *g_fy, real *g_fz,
    real *g_virial, real *g_potential,
    real *g_h, int *g_label, int *g_fv_index, real *g_fv,
    int *g_a_map, int *g_b_map, int g_count_b
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1; // particle index
    real s_fx = ZERO; // force_x
    real s_fy = ZERO; // force_y
    real s_fz = ZERO; // force_z
    real s_pe = ZERO; // potential energy
    real s_sxx = ZERO; // virial_stress_xx
    real s_sxy = ZERO; // virial_stress_xy
    real s_sxz = ZERO; // virial_stress_xz
    real s_syx = ZERO; // virial_stress_yx
    real s_syy = ZERO; // virial_stress_yy
    real s_syz = ZERO; // virial_stress_yz
    real s_szx = ZERO; // virial_stress_zx
    real s_szy = ZERO; // virial_stress_zy
    real s_szz = ZERO; // virial_stress_zz
    real s_h1 = ZERO; // heat_x_in
    real s_h2 = ZERO; // heat_x_out
    real s_h3 = ZERO; // heat_y_in
    real s_h4 = ZERO; // heat_y_out
    real s_h5 = ZERO; // heat_z

    // driving force
    real fx_driving = ZERO;
    real fy_driving = ZERO;
    real fz_driving = ZERO;

    if (n1 >= N1 && n1 < N2)
    {
        int neighbor_number = g_neighbor_number[n1];
        int type1 = g_type[n1] - shift;
        real x1 = LDG(g_x, n1);
        real y1 = LDG(g_y, n1);
        real z1 = LDG(g_z, n1);
        real vx1, vy1, vz1;
        if (cal_j || cal_q || cal_k)
        {
            vx1 = LDG(g_vx, n1);
            vy1 = LDG(g_vy, n1);
            vz1 = LDG(g_vz, n1);
        }

        for (int i1 = 0; i1 < neighbor_number; ++i1)
        {
            int n2 = g_neighbor_list[n1 + number_of_particles * i1];
            int type2 = g_type[n2] - shift;

            real x12  = LDG(g_x, n2) - x1;
            real y12  = LDG(g_y, n2) - y1;
            real z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(triclinic, pbc_x, pbc_y, pbc_z, g_box, x12, y12, z12);
            real d12sq = x12 * x12 + y12 * y12 + z12 * z12;

            real p2, f2;
            if (d12sq >= lj.cutoff_square[type1][type2]) {continue;}
            find_p2_and_f2
            (lj.s6e4[type1][type2], lj.s12e4[type1][type2], d12sq, p2, f2);

            // treat two-body potential in the same way as many-body potential
            real f12x = f2 * x12 * HALF;
            real f12y = f2 * y12 * HALF;
            real f12z = f2 * z12 * HALF;
            real f21x = -f12x;
            real f21y = -f12y;
            real f21z = -f12z;

            // accumulate force
            s_fx += f12x - f21x;
            s_fy += f12y - f21y;
            s_fz += f12z - f21z;

            // driving force
            if (cal_k)
            {
                fx_driving += f21x * (x12 * fe_x + y12 * fe_y + z12 * fe_z);
                fy_driving += f21y * (x12 * fe_x + y12 * fe_y + z12 * fe_z);
                fz_driving += f21z * (x12 * fe_x + y12 * fe_y + z12 * fe_z);
            }

            // accumulate potential energy and virial
            s_pe += p2 * HALF; // two-body potential
            s_sxx += x12 * f21x;
            s_sxy += x12 * f21y;
            s_sxz += x12 * f21z;
            s_syx += y12 * f21x;
            s_syy += y12 * f21y;
            s_syz += y12 * f21z;
            s_szx += z12 * f21x;
            s_szy += z12 * f21y;
            s_szz += z12 * f21z;

            // per-atom heat current
            if (cal_j || cal_k)
            {
                s_h1 += (f21x * vx1 + f21y * vy1) * x12;  // x-in
                s_h2 += (f21z * vz1) * x12;               // x-out
                s_h3 += (f21x * vx1 + f21y * vy1) * y12;  // y-in
                s_h4 += (f21z * vz1) * y12;               // y-out
                s_h5 += (f21x*vx1+f21y*vy1+f21z*vz1)*z12; // z-all
            }

            // accumulate heat across some sections (for NEMD)
            //        check if AB pair possible & exists
            if (cal_q && g_a_map[n1] != -1 && g_b_map[n2] != -1 &&
                    g_fv_index[g_a_map[n1] * g_count_b + g_b_map[n2]] != -1)
            {
                int index_12 = g_fv_index[g_a_map[n1] * g_count_b + g_b_map[n2]] * 12;
                g_fv[index_12 + 0]  += f12x;
                g_fv[index_12 + 1]  += f12y;
                g_fv[index_12 + 2]  += f12z;
                g_fv[index_12 + 3]  += f21x;
                g_fv[index_12 + 4]  += f21y;
                g_fv[index_12 + 5]  += f21z;
                g_fv[index_12 + 6]  = vx1;
                g_fv[index_12 + 7]  = vy1;
                g_fv[index_12 + 8]  = vz1;
                g_fv[index_12 + 9]  = LDG(g_vx, n2);
                g_fv[index_12 + 10] = LDG(g_vy, n2);
                g_fv[index_12 + 11] = LDG(g_vz, n2);
            }
        }

        // add driving force
        if (cal_k)
        {
            s_fx += fx_driving;
            s_fy += fy_driving;
            s_fz += fz_driving;
        }

        // save force
        g_fx[n1] += s_fx;
        g_fy[n1] += s_fy;
        g_fz[n1] += s_fz;

        // save virial
        // xx xy xz    0 3 4
        // yx yy yz    6 1 5
        // zx zy zz    7 8 2
        g_virial[n1 + 0 * number_of_particles] += s_sxx;
        g_virial[n1 + 1 * number_of_particles] += s_syy;
        g_virial[n1 + 2 * number_of_particles] += s_szz;
        g_virial[n1 + 3 * number_of_particles] += s_sxy;
        g_virial[n1 + 4 * number_of_particles] += s_sxz;
        g_virial[n1 + 5 * number_of_particles] += s_syz;
        g_virial[n1 + 6 * number_of_particles] += s_syx;
        g_virial[n1 + 7 * number_of_particles] += s_szx;
        g_virial[n1 + 8 * number_of_particles] += s_szy;

        // save potential
        g_potential[n1] += s_pe;

        // save heat current
        if (cal_j || cal_k)
        {
            g_h[n1 + 0 * number_of_particles] += s_h1;
            g_h[n1 + 1 * number_of_particles] += s_h2;
            g_h[n1 + 2 * number_of_particles] += s_h3;
            g_h[n1 + 3 * number_of_particles] += s_h4;
            g_h[n1 + 4 * number_of_particles] += s_h5;
        }
    }
}


// Find force and related quantities for pair potentials (A wrapper)
void LJ::compute(Atom *atom, Measure *measure, int potential_number)
{
    find_measurement_flags(atom, measure);
    int shift = atom->shift[potential_number];
    int grid_size = (N2 - N1 - 1) / BLOCK_SIZE_FORCE + 1;

    if (compute_j)
    {
        GPU_FIND_FORCE(1, 0, 0);
    }
    else if (compute_shc && !measure->hnemd.compute)
    {
        GPU_FIND_FORCE(0, 1, 0);
    }
    else if (measure->hnemd.compute && !compute_shc)
    {
        GPU_FIND_FORCE(0, 0, 1);
    }
    else if (measure->hnemd.compute && compute_shc)
    {
        GPU_FIND_FORCE(0, 1, 1);
    }
    else
    {
        GPU_FIND_FORCE(0, 0, 0);
    }
    CUDA_CHECK_KERNEL

}
