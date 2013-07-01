/******************************************************************************
 * Copyright (c) 2011, Duane Merrill.  All rights reserved.
 * Copyright (c) 2011-2013, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

/******************************************************************************
 * Test of DeviceReduce utilities
 ******************************************************************************/

// Ensure printing of CUDA runtime errors to console
#define CUB_STDERR

#include <stdio.h>
#include <cub/cub.cuh>
#include "test_util.h"

using namespace cub;


//---------------------------------------------------------------------
// Globals, constants and typedefs
//---------------------------------------------------------------------

bool                    g_verbose = false;
int                     g_iterations = 100;
CachingDeviceAllocator  g_allocator;


//---------------------------------------------------------------------
// CUDA Nested Parallelism Test Kernel
//---------------------------------------------------------------------

/**
 * Simple wrapper kernel to invoke DeviceReduce
 */
template <
    bool                STREAM_SYNCHRONOUS,
    typename            InputIteratorRA,
    typename            OutputIteratorRA,
    typename            ReductionOp>
__global__ void CnpReduce(
    void                *d_temporary_storage,
    size_t              temporary_storage_bytes,
    InputIteratorRA     d_in,
    OutputIteratorRA    d_out,
    int                 num_items,
    ReductionOp         reduction_op,
    int                 iterations,
    cudaError_t*        d_cnp_error)
{
    cudaError_t error = cudaSuccess;

#ifdef CUB_RUNTIME_ENABLED
    for (int i = 0; i < iterations; ++i)
    {
        error = DeviceReduce::Reduce(
            d_temporary_storage,
            temporary_storage_bytes,
            d_in,
            d_out,
            num_items,
            reduction_op,
            0,
            STREAM_SYNCHRONOUS);
    }
#else
    error = cudaErrorNotSupported;
#endif

    *d_cnp_error = error;
}


//---------------------------------------------------------------------
// Host utility subroutines
//---------------------------------------------------------------------

/**
 * Initialize problem (and solution)
 */
template <
    typename        T,
    typename        ReductionOp>
void Initialize(
    GenMode         gen_mode,
    T               *h_in,
    T               h_reference[1],
    ReductionOp     reduction_op,
    int             num_items)
{
    for (int i = 0; i < num_items; ++i)
    {
        InitValue(gen_mode, h_in[i], i);
        if (i == 0)
            h_reference[0] = h_in[0];
        else
            h_reference[0] = reduction_op(h_reference[0], h_in[i]);
    }
}


//---------------------------------------------------------------------
// Full tile test generation
//---------------------------------------------------------------------


/**
 * Test DeviceReduce
 */
template <
    typename    T,
    typename    ReductionOp>
void Test(
    int         num_items,
    GenMode     gen_mode,
    ReductionOp reduction_op,
    char*       type_string)
{
    int compare = 0;
    int cnp_compare = 0;

    printf("cub::DeviceReduce %d items, %s %d-byte elements, gen-mode %d\n\n",
        num_items, type_string, (int) sizeof(T), gen_mode);
    fflush(stdout);

    // Allocate host arrays
    T*              h_in = new T[num_items];
    T               h_reference[1];

    // Initialize problem
    Initialize(gen_mode, h_in, h_reference, reduction_op, num_items);

    // Allocate device arrays
    T*              d_in = NULL;
    T*              d_out = NULL;
    cudaError_t*    d_cnp_error = NULL;
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_in,          sizeof(T) * num_items));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_out,         sizeof(T) * 1));
    CubDebugExit(g_allocator.DeviceAllocate((void**)&d_cnp_error,   sizeof(cudaError_t) * 1));

    // Initialize device arrays
    CubDebugExit(cudaMemcpy(d_in, h_in, sizeof(T) * num_items, cudaMemcpyHostToDevice));
    CubDebugExit(cudaMemset(d_out, 0, sizeof(T) * 1));

    void            *d_temporary_storage = NULL;
    size_t          temporary_storage_bytes = 0;

    // Allocate temporary storage
    CubDebugExit(DeviceReduce::Reduce(d_temporary_storage, temporary_storage_bytes, d_in, d_out, num_items, reduction_op));
    CubDebugExit(g_allocator.DeviceAllocate(&d_temporary_storage, temporary_storage_bytes));

    // Run warmup/correctness iteration
    printf("Host dispatch:\n"); fflush(stdout);
    CubDebugExit(DeviceReduce::Reduce(d_temporary_storage, temporary_storage_bytes, d_in, d_out, num_items, reduction_op, 0, true));

    // Check for correctness (and display results, if specified)
    compare = CompareDeviceResults(h_reference, d_out, 1, g_verbose, g_verbose);
    printf("\n%s", compare ? "FAIL" : "PASS");

    // Flush any stdout/stderr
    fflush(stdout);
    fflush(stderr);

    // Performance
    GpuTimer gpu_timer;
    float elapsed_millis = 0.0;
    for (int i = 0; i < g_iterations; i++)
    {
        gpu_timer.Start();

        CubDebugExit(DeviceReduce::Reduce(d_temporary_storage, temporary_storage_bytes, d_in, d_out, num_items, reduction_op));

        gpu_timer.Stop();
        elapsed_millis += gpu_timer.ElapsedMillis();
    }
    if (g_iterations > 0)
    {
        float avg_millis = elapsed_millis / g_iterations;
        float grate = float(num_items) / avg_millis / 1000.0 / 1000.0;
        float gbandwidth = grate * sizeof(T);
        printf(", %.3f avg ms, %.3f billion items/s, %.3f GB/s\n", avg_millis, grate, gbandwidth);
    }
    else
    {
        printf("\n");
    }


    // Evaluate using CUDA nested parallelism
#if (TEST_CNP == 1)

    CubDebugExit(cudaMemset(d_out, 0, sizeof(T) * 1));

    // Run warmup/correctness iteration
    printf("\nDevice dispatch:\n"); fflush(stdout);
    CnpReduce<true><<<1,1>>>(d_temporary_storage, temporary_storage_bytes, d_in, d_out, num_items, reduction_op, 1, d_cnp_error);

    // Flush any stdout/stderr
    fflush(stdout);
    fflush(stderr);

    // Check if we were compiled and linked for CNP
    cudaError_t h_cnp_error;
    CubDebugExit(cudaMemcpy(&h_cnp_error, d_cnp_error, sizeof(cudaError_t) * 1, cudaMemcpyDeviceToHost));
    if (h_cnp_error == cudaErrorInvalidConfiguration)
    {
        printf("CNP not supported");
    }
    else
    {
        CubDebugExit(h_cnp_error);

        // Check for correctness (and display results, if specified)
        cnp_compare = CompareDeviceResults(h_reference, d_out, 1, g_verbose, g_verbose);
        printf("\n%s", cnp_compare ? "FAIL" : "PASS");

        // Performance
        gpu_timer.Start();

        CnpReduce<false><<<1,1>>>(d_temporary_storage, temporary_storage_bytes, d_in, d_out, num_items, reduction_op, g_iterations, d_cnp_error);

        gpu_timer.Stop();
        elapsed_millis = gpu_timer.ElapsedMillis();

        if (g_iterations > 0)
        {
            float avg_millis = elapsed_millis / g_iterations;
            float grate = float(num_items) / avg_millis / 1000.0 / 1000.0;
            float gbandwidth = grate * sizeof(T);
            printf(", %.3f avg ms, %.3f billion items/s, %.3f GB/s\n", avg_millis, grate, gbandwidth);
        }
        else
        {
            printf("\n");
        }
    }

#endif

    // Cleanup
    if (h_in) delete[] h_in;
    if (d_in) CubDebugExit(g_allocator.DeviceFree(d_in));
    if (d_out) CubDebugExit(g_allocator.DeviceFree(d_out));
    if (d_cnp_error) CubDebugExit(g_allocator.DeviceFree(d_cnp_error));
    if (d_temporary_storage) CubDebugExit(g_allocator.DeviceFree(d_temporary_storage));

    // Correctness asserts
    AssertEquals(0, compare);
    AssertEquals(0, cnp_compare);
}




//---------------------------------------------------------------------
// Main
//---------------------------------------------------------------------

/**
 * Run battery of full-tile tests for different gen modes
 */
template <
    typename        T,
    typename        ReductionOp>
void Test(
    int             num_items,
    ReductionOp     reduction_op,
    char*           type_string)
{
    Test<T>(num_items, UNIFORM, reduction_op, type_string);
    Test<T>(num_items, SEQ_INC, reduction_op, type_string);
    Test<T>(num_items, RANDOM, reduction_op, type_string);
}


/**
 * Main
 */
int main(int argc, char** argv)
{
    int num_items = 1 * 1024 * 1024;

    // Initialize command line
    CommandLineArgs args(argc, argv);
    args.GetCmdLineArgument("n", num_items);
    args.GetCmdLineArgument("i", g_iterations);
    g_verbose = args.CheckCmdLineFlag("v");
    bool quick = args.CheckCmdLineFlag("quick");

    // Print usage
    if (args.CheckCmdLineFlag("help"))
    {
        printf("%s "
            "[--device=<device-id>] "
            "[--v] "
            "[--cnp]"
            "\n", argv[0]);
        exit(0);
    }

    // Initialize device
    CubDebugExit(args.DeviceInit());

    // Quick test
    typedef int T;
    Test<T>(num_items, UNIFORM, Sum(), CUB_TYPE_STRING(T));

/*
    // primitives
    Test<char>(Sum(), CUB_TYPE_STRING(char));
    Test<short>(Sum>(), CUB_TYPE_STRING(short));
    Test<int>(Sum(), CUB_TYPE_STRING(int));
    Test<long long>(Sum(), CUB_TYPE_STRING(long long));

    // vector types
    Test<char2>(Sum(), CUB_TYPE_STRING(char2));
    Test<short2>(Sum(), CUB_TYPE_STRING(short2));
    Test<int2>(Sum(), CUB_TYPE_STRING(int2));
    Test<longlong2>(Sum(), CUB_TYPE_STRING(longlong2));

    Test<char4>(Sum(), CUB_TYPE_STRING(char4));
    Test<short4>(Sum(), CUB_TYPE_STRING(short4));
    Test<int4>(Sum(), CUB_TYPE_STRING(int4));
    Test<longlong4>(Sum(), CUB_TYPE_STRING(longlong4));

    // Complex types
    Test<TestFoo>(Sum(), CUB_TYPE_STRING(TestFoo));
    Test<TestBar>(Sum(), CUB_TYPE_STRING(TestBar));
*/
    return 0;
}



