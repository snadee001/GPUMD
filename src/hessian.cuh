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


#pragma once
#include "gpu_vector.cuh"
#include <vector>
#include <stdio.h>

class Box;
class Neighbor;
class Group;
class Atom;
class Force;


class Hessian
{
public:
    double displacement = 0.005;
    double cutoff = 4.0;
    void compute(char*, Atom*, Force*);
    void parse_cutoff(char**, size_t);
    void parse_delta(char**, size_t);

protected:

    size_t num_basis;
    size_t num_kpoints;

    std::vector<size_t> basis;
    std::vector<size_t> label;
    std::vector<double> mass;
    std::vector<double> kpoints;
    std::vector<double> H;
    std::vector<double> DR;
    std::vector<double> DI;

    void shift_atom
    (
        const double dx,
        const size_t n2,
        const size_t beta,
        GPU_Vector<double>& position_per_atom
    );

    void get_f
    (
        const double dx,
        const size_t n1,
        const size_t n2,
        const size_t beta,
        const Box& box,
        GPU_Vector<double>& position_per_atom,
        GPU_Vector<int>& type,
        std::vector<Group>& group,
        Neighbor& neighbor,
        GPU_Vector<double>& potential_per_atom,
        GPU_Vector<double>& force_per_atom,
        GPU_Vector<double>& virial_per_atom,
        Force *force,
        double* f
    );

    void read_basis(char*, size_t N);
    void read_kpoints(char*);
    void initialize(char*, size_t);
    void finalize(void);
    void find_H(Atom*, Force*);
    void find_H12(size_t, size_t, Atom*, Force*, double*);
    bool is_too_far(size_t, size_t, Atom*);
    void find_dispersion(char*, Atom*);
    void find_D(Atom*);
    void find_eigenvectors(char*, Atom*);
    void output_D(char*);
    void find_omega(FILE*, size_t);
    void find_omega_batch(FILE*);
};


