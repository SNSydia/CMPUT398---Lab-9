#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <wb.h>

#define BLOCK_SIZE 512 //TODO: You can change this

#define wbCheck(ans) { gpuAssert((ans), __FILE__, __LINE__); }

inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort = true)
{
	if (code != cudaSuccess)
	{
		fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
		if (abort) exit(code);
	}
}
__global__ void blockadd(int* g_aux, int* g_odata, int length){
	int id = blockIdx.x*blockDim.x + threadIdx.x;

	if (id < length && blockIdx.x > 0){
		g_odata[id] += g_aux[blockIdx.x];
	}

}

__global__ void split(int *in_d, int *out_d, int length, int shamt) {
    int index = threadIdx.x + blockDim.x * blockIdx.x;
	int bit = 0;

	if (index < length) {
		bit = in_d[index] & (1 << shamt);

		if (bit > 0)
            bit = 1;
        else
            bit = 0;

		__syncthreads();

		out_d[index] = 1 - bit;
	}

}

__global__ void indef(int *in_d,  int *rev_bit_d,  int length,  int last_input) {
	int index = threadIdx.x + blockDim.x * blockIdx.x;

	int x = in_d[length - 1] + rev_bit_d[length-1];
	__syncthreads();

	if (index < length) {
		if (rev_bit_d[index] == 0) {
			__syncthreads();
			int val = in_d[index];
			in_d[index] = index - val + x;
		}
	}

}

__global__ void scatter( int *in_d,  int *index_d,  int *out_d,  int length) {
	int index = threadIdx.x + blockDim.x * blockIdx.x;

	if (index < length) {
		int val = index_d[index];
		__syncthreads();
		if (val < length){
			out_d[val] = in_d[index];
		}

	}
}

__global__ void scan(int*g_odata, int *g_idata, int *g_aux, int length){

	int thread = blockIdx.x * blockDim.x + threadIdx.x;
	__shared__ int temp[BLOCK_SIZE];


	if (thread < length){
		temp[threadIdx.x] = g_idata[thread];
	}

	for (unsigned int stride = 1; stride <= threadIdx.x; stride *= 2){
		__syncthreads();
		int in1 = 0;

		if (threadIdx.x >= stride){
			in1 = temp[threadIdx.x - stride];
		}
		__syncthreads();
		temp[threadIdx.x] += in1;
	}

	__syncthreads();

	if (thread + 1 < length)
        g_odata[thread + 1] = temp[threadIdx.x];

	if (g_aux != NULL && threadIdx.x == blockDim.x - 1){

		g_aux[blockIdx.x] = g_odata[thread + 1];
		g_odata[thread + 1] = 0;
	}
}

void swap(int* in, int* out){

    int *tmp;
    tmp = in;
    in = out;
    out = tmp;
}

void sort(int* deviceInput, int *deviceOutput, int numElements)
{
	//TODO: Modify this to complete the functionality of the sort on the deivce
	int numBlocks = (numElements / BLOCK_SIZE) + 1;
	int *help; int *help2;


	dim3 block(BLOCK_SIZE, 1);
	dim3 grid(numBlocks, 1);

	cudaMalloc(&help, sizeof(int)*numElements);
	cudaMalloc(&help2, sizeof(int)*numElements);

	for (int bit = 0; bit < 15; bit++){

		split<<<grid, block>>>(deviceInput, deviceOutput, numElements, bit);
		cudaDeviceSynchronize();

		scan << <grid, block >> >(help2, deviceOutput, NULL, numElements);
		cudaDeviceSynchronize();

		indef << <grid, block >> >(help2, deviceOutput, numElements, deviceInput[numElements - 1]);
		cudaDeviceSynchronize();

		scatter<<<grid, block>>>(deviceInput, help2, deviceOutput, numElements);
		cudaDeviceSynchronize();

		swap(deviceImput, deviceOutput);
}


int main(int argc, char **argv) {
	wbArg_t args;
	int *hostInput;  // The input 1D list
	int *hostOutput; // The output list
	int *deviceInput;
	int *deviceOutput;
	int numElements; // number of elements in the list

	args = wbArg_read(argc, argv);

	wbTime_start(Generic, "Importing data and creating memory on host");
	hostInput = (int *)wbImport(wbArg_getInputFile(args, 0), &numElements, "integral_vector");
	cudaHostAlloc(&hostOutput, numElements * sizeof(int), cudaHostAllocDefault);
	wbTime_stop(Generic, "Importing data and creating memory on host");

	wbLog(TRACE, "The number of input elements in the input is ", numElements);

	wbTime_start(GPU, "Allocating GPU memory.");
	wbCheck(cudaMalloc((void **)&deviceInput, numElements * sizeof(int)));
	wbCheck(cudaMalloc((void **)&deviceOutput, numElements * sizeof(int)));
	wbTime_stop(GPU, "Allocating GPU memory.");

	wbTime_start(GPU, "Clearing output memory.");
	wbCheck(cudaMemset(deviceOutput, 0, numElements * sizeof(int)));
	wbTime_stop(GPU, "Clearing output memory.");

	wbTime_start(GPU, "Copying input memory to the GPU.");
	wbCheck(cudaMemcpy(deviceInput, hostInput, numElements * sizeof(int),
		cudaMemcpyHostToDevice));
	wbTime_stop(GPU, "Copying input memory to the GPU.");

	wbTime_start(Compute, "Performing CUDA computation");
	sort(deviceInput, deviceOutput, numElements);
	wbTime_stop(Compute, "Performing CUDA computation");

	wbTime_start(Copy, "Copying output memory to the CPU");
	wbCheck(cudaMemcpy(hostOutput, deviceOutput, numElements * sizeof(float),
		cudaMemcpyDeviceToHost));
	wbTime_stop(Copy, "Copying output memory to the CPU");

	wbTime_start(GPU, "Freeing GPU Memory");
	cudaFree(deviceInput);
	cudaFree(deviceOutput);
	wbTime_stop(GPU, "Freeing GPU Memory");

	wbSolution(args, hostOutput, numElements);

	free(hostInput);
	cudaFreeHost(hostOutput);

#if LAB_DEBUG
	system("pause");
#endif

	return 0;
}
