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
The driver class for minimizers.
------------------------------------------------------------------------------*/


#include "minimize.cuh"
#include "minimizer_sd.cuh"
#include "force/force.cuh"
#include "utilities/error.cuh"
#include "utilities/read_file.cuh"
#include <memory>


void Minimize::parse_minimize
(
    char** param, 
    int num_param,
    Force& force,
    Box& box,
    GPU_Vector<double>& position_per_atom,
    GPU_Vector<int>& type,
    std::vector<Group>& group,
    Neighbor& neighbor,
    GPU_Vector<double>& potential_per_atom,
    GPU_Vector<double>& force_per_atom,
    GPU_Vector<double>& virial_per_atom
)
{
    
    int minimizer_type = 0; 
    int number_of_steps = 0;
    std::unique_ptr<Minimizer> minimizer;
    const int number_of_atoms = type.size();

    if (strcmp(param[1], "sd") == 0)
    {
        minimizer_type = 0;

        if (num_param != 3)
        {
            PRINT_INPUT_ERROR("minimize sd should have 1 parameter.");
        }

        if (!is_valid_int(param[2], &number_of_steps))
        {
            PRINT_INPUT_ERROR("Number of steps should be an integer.");
        }
        if (number_of_steps <= 0)
        {
            PRINT_INPUT_ERROR("Number of steps should > 0.");
        }
    }
    else
    {
        PRINT_INPUT_ERROR("Invalid minimizer.");
    }

    switch (minimizer_type)
    {
    case 0:
        printf
        (
            "\nMinimize for %d steps with steepest descent (fixed box).\n", 
            number_of_steps
        );

        minimizer = std::make_unique<Minimizer_SD>
        (
            number_of_atoms,
            number_of_steps
        );

        minimizer->compute
        (  
            force,      
            box,
            position_per_atom,
            type,
            group,
            neighbor,
            potential_per_atom,
            force_per_atom,
            virial_per_atom
        );

        break;
    default:
        PRINT_INPUT_ERROR("Invalid minimizer.");
        break; 
    }
}

