/*-------------------------------------------------------------------------
 *
 * CUDA functions for Steepest descend in POCS-type algorithms.
 *
 * This file will iteratively minimize by stepest descend the total variation
 * of the input image, with the parameters given, using GPUs.
 *
 * CODE by       Ander Biguri
 *
 * ---------------------------------------------------------------------------
 * ---------------------------------------------------------------------------
 * Copyright (c) 2015, University of Bath and CERN- European Organization for
 * Nuclear Research
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * 3. Neither the name of the copyright holder nor the names of its contributors
 * may be used to endorse or promote products derived from this software without
 * specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 * ---------------------------------------------------------------------------
 *
 * Contact: tigre.toolbox@gmail.com
 * Codes  : https://github.com/CERN/TIGRE
 * ---------------------------------------------------------------------------
 */







#define MAXTHREADS 1024

#include "POCS_TV.hpp"




#define cudaCheckErrors(msg) \
do { \
        cudaError_t __err = cudaGetLastError(); \
        if (__err != cudaSuccess) { \
                mexPrintf("%s \n",msg);\
                cudaDeviceReset();\
                        mexErrMsgIdAndTxt("CBCT:CUDA:POCS_TV",cudaGetErrorString(__err));\
        } \
} while (0)
    
// CUDA kernels
//https://stackoverflow.com/questions/21332040/simple-cuda-kernel-optimization/21340927#21340927
    __global__ void divideArrayScalar(float* vec,float scalar,const size_t n){
        unsigned long long i = (blockIdx.x * blockDim.x) + threadIdx.x;
        for(; i<n; i+=gridDim.x*blockDim.x) {
            vec[i]/=scalar;
        }
    }
    __global__ void multiplyArrayScalar(float* vec,float scalar,const size_t n)
    {
        unsigned long long i = (blockIdx.x * blockDim.x) + threadIdx.x;
        for(; i<n; i+=gridDim.x*blockDim.x) {
            vec[i]*=scalar;
        }
    }
    __global__ void substractArrays(float* vec,float* vec2,const size_t n)
    {
        unsigned long long i = (blockIdx.x * blockDim.x) + threadIdx.x;
        for(; i<n; i+=gridDim.x*blockDim.x) {
            vec[i]-=vec2[i];
        }
    }
    
    __device__ __inline__
            void gradient(const float* u, float* grad,
            long z, long y, long x,
            long depth, long rows, long cols)
    {
        unsigned long size2d = rows*cols;
        unsigned long long idx = z * size2d + y * cols + x;
        
        float uidx = u[idx];
        
        if ( z - 1 >= 0 && z<depth) {
            grad[0] = (uidx-u[(z-1)*size2d + y*cols + x]) ;
        }
        
        if ( y - 1 >= 0 && y<rows){
            grad[1] = (uidx-u[z*size2d + (y-1)*cols + x]) ;
        }
        
        if ( x - 1 >= 0 && x<cols) {
            grad[2] = (uidx-u[z*size2d + y*cols + (x-1)]);
        }
    }
    
    __global__ void gradientTV(const float* f, float* dftv,
            long depth, long rows, long cols){
        unsigned long x = threadIdx.x + blockIdx.x * blockDim.x;
        unsigned long y = threadIdx.y + blockIdx.y * blockDim.y;
        unsigned long z = threadIdx.z + blockIdx.z * blockDim.z;
        unsigned long long idx = z * rows * cols + y * cols + x;
        if ( x >= cols || y >= rows || z >= depth )
            return;
        
        float df[3] ={0,0,0};
        float dfi[3]={0,0,0}; // dfi== \partial f_{i+1,j,k}
        float dfj[3]={0,0,0};
        float dfk[3]={0,0,0};
        gradient(f,df  ,z  ,y  ,x  , depth,rows,cols);
        gradient(f,dfi ,z  ,y  ,x+1, depth,rows,cols);
        gradient(f,dfj ,z  ,y+1,x  , depth,rows,cols);
        gradient(f,dfk ,z+1,y  ,x  , depth,rows,cols);
        float eps=0.00000001; //% avoid division by zero
        dftv[idx]=(df[0]+df[1]+df[2])/(sqrt(df[0] *df[0] +df[1] *df[1] +df[2] *df[2])+eps)
        -dfi[2]/(sqrt(dfi[0]*dfi[0]+dfi[1]*dfi[1]+dfi[2]*dfi[2]) +eps)     // I wish I coudl precompute this, but if I do then Id need to recompute the gradient.
        -dfj[1]/(sqrt(dfj[0]*dfj[0]+dfj[1]*dfj[1]+dfj[2]*dfj[2]) +eps)
        -dfk[0]/(sqrt(dfk[0]*dfk[0]+dfk[1]*dfk[1]+dfk[2]*dfk[2]) +eps);
        
    }
    
    __device__ void warpReduce(volatile float *sdata, size_t tid) {
        sdata[tid] += sdata[tid + 32];
        sdata[tid] += sdata[tid + 16];
        sdata[tid] += sdata[tid + 8];
        sdata[tid] += sdata[tid + 4];
        sdata[tid] += sdata[tid + 2];
        sdata[tid] += sdata[tid + 1];
    }
    
    __global__ void  reduceNorm2(float *g_idata, float *g_odata, size_t n){
        extern __shared__ volatile float sdata[];
        //http://stackoverflow.com/a/35133396/1485872
        size_t tid = threadIdx.x;
        size_t i = blockIdx.x*blockDim.x + tid;
        size_t gridSize = blockDim.x*gridDim.x;
        float mySum = 0;
        float value=0;
        while (i < n) {
            value=g_idata[i]; //avoid reading twice
            mySum += value*value;
            i += gridSize;
        }
        sdata[tid] = mySum;
        __syncthreads();
        
        if (tid < 512)
            sdata[tid] += sdata[tid + 512];
        __syncthreads();
        if (tid < 256)
            sdata[tid] += sdata[tid + 256];
        __syncthreads();
        
        if (tid < 128)
            sdata[tid] += sdata[tid + 128];
        __syncthreads();
        
        if (tid <  64)
            sdata[tid] += sdata[tid + 64];
        __syncthreads();
        
        
#if (__CUDA_ARCH__ >= 300)
        if ( tid < 32 )
        {
            mySum = sdata[tid] + sdata[tid + 32];
            for (int offset = warpSize/2; offset > 0; offset /= 2) {
                mySum += __shfl_down_sync(0xFFFFFFFF,mySum, offset);
            }
        }
#else
        if (tid < 32) {
            warpReduce(sdata, tid);
            mySum = sdata[0];
        }
#endif
        if (tid == 0) g_odata[blockIdx.x] = mySum;
    }
    
    __global__ void  reduceSum(float *g_idata, float *g_odata, size_t n){
        extern __shared__ volatile float sdata[];
        //http://stackoverflow.com/a/35133396/1485872
        size_t tid = threadIdx.x;
        size_t i = blockIdx.x*blockDim.x + tid;
        size_t gridSize = blockDim.x*gridDim.x;
        float mySum = 0;
        // float value=0;
        while (i < n) {
            mySum += g_idata[i];
            i += gridSize;
        }
        sdata[tid] = mySum;
        __syncthreads();
        
        if (tid < 512)
            sdata[tid] += sdata[tid + 512];
        __syncthreads();
        if (tid < 256)
            sdata[tid] += sdata[tid + 256];
        __syncthreads();
        
        if (tid < 128)
            sdata[tid] += sdata[tid + 128];
        __syncthreads();
        
        if (tid <  64)
            sdata[tid] += sdata[tid + 64];
        __syncthreads();
        
        
#if (__CUDA_ARCH__ >= 300)
        if ( tid < 32 )
        {
            mySum = sdata[tid] + sdata[tid + 32];
            for (int offset = warpSize/2; offset > 0; offset /= 2) {
                mySum += __shfl_down_sync(0xFFFFFFFF,mySum, offset);
            }
        }
#else
        if (tid < 32) {
            warpReduce(sdata, tid);
            mySum = sdata[0];
        }
#endif
        if (tid == 0) g_odata[blockIdx.x] = mySum;
    }
    
    
    
    
// main function
    void pocs_tv(const float* img,float* dst,float alpha,const long* image_size, int maxIter){
        
        
        
        
        // Prepare for MultiGPU
        int deviceCount = 0;
        cudaGetDeviceCount(&deviceCount);
        cudaCheckErrors("Device query fail");
        if (deviceCount == 0) {
            mexErrMsgIdAndTxt("minimizeTV:POCS_TV:GPUselect","There are no available device(s) that support CUDA\n");
        }
        //
        // CODE assumes
        // 1.-All available devices are usable by this code
        // 2.-All available devices are equal, they are the same machine (warning trhown)
        int dev;
        char * devicenames;
        cudaDeviceProp deviceProp;
        
        for (dev = 0; dev < deviceCount; dev++) {
            cudaSetDevice(dev);
            cudaGetDeviceProperties(&deviceProp, dev);
            if (dev>0){
                if (strcmp(devicenames,deviceProp.name)!=0){
                    mexWarnMsgIdAndTxt("minimizeTV:POCS_TV:GPUselect","Detected one (or more) different GPUs.\n This code is not smart enough to separate the memory GPU wise if they have different computational times or memory limits.\n First GPU parameters used. If the code errors you might need to change the way GPU selection is performed. \n POCS_TV.cu line 277.");
                    break;
                }
            }
            devicenames=deviceProp.name;
        }
        cudaSetDevice(0);
        cudaGetDeviceProperties(&deviceProp, 0);
        
        // %5 of free memory shoudl be enough, we have almsot no variables in these kernels
        unsigned long long mem_GPU_global=(unsigned long long)(deviceProp.totalGlobalMem*0.95);
        size_t total_pixels              = image_size[0] * image_size[1]  * image_size[2] ;
        size_t mem_slice_image           = image_size[0] * image_size[1]*sizeof(float);
        size_t mem_size_image            = sizeof(float) * total_pixels;
        size_t mem_auxiliary             = sizeof(float)*(total_pixels + MAXTHREADS - 1) / MAXTHREADS;
        
        // Decide how are we handling the distribution of computation
        size_t mem_img_each_GPU;
        //Does everything fit in the GPU?
        bool fits_in_memory=false;
        unsigned int slices_per_split;
        unsigned int splits=1; // if the number does not fit in an uint, you have more serious trouble than this.
        if(mem_GPU_global> 3*mem_size_image+3*(deviceCount-1)*mem_slice_image+mem_auxiliary){
            // We only need to split if we have extra GPUs
            fits_in_memory=true;
            slices_per_split=(image_size[2]+deviceCount-1)/deviceCount;
            mem_img_each_GPU=mem_slice_image*((image_size[2]+2+deviceCount-1)/deviceCount);
        }else{
            fits_in_memory=false;
            // As mem_auxiliary is not expected to be a large value (for a 2000^3 image is around 28Mbytes), lets for now assume we need it all
            size_t mem_free=mem_GPU_global-mem_auxiliary;
            
            splits=(unsigned int)(ceil(((float)(3*mem_size_image)/(float)(deviceCount))/mem_free));
            // Now, there is an overhead here, as each splits should have 2 slices more, to accoutn for overlap of images.
            // lets make sure these 2 slices fit, if they do not, add 1 to splits.
            slices_per_split=(image_size[2]+deviceCount*splits-1)/(deviceCount*splits);
            mem_img_each_GPU=(mem_slice_image*(slices_per_split+2));
            // if the new stuff does not fit in the GPU, it measn we are in the edge case where adding that extra slice will overflow memory
            if (mem_GPU_global< 3*mem_img_each_GPU+mem_auxiliary){
                // one more splot shoudl do the job, as its an edge case.
                splits++;
                //recompute for later
                slices_per_split=(image_size[2]+deviceCount*splits-1)/(deviceCount*splits); // amountf of slices that fit on a GPU. Later we add 2 to these, as we need them for overlap
                mem_img_each_GPU=(mem_slice_image*(slices_per_split+2));
            }
            
            
        }
        
        
        
        float** d_image=    (float**)malloc(deviceCount*sizeof(float*));
        float** d_dimgTV=   (float**)malloc(deviceCount*sizeof(float*));
        float** d_norm2aux= (float**)malloc(deviceCount*sizeof(float*));
        float** d_norm2=    (float**)malloc(deviceCount*sizeof(float*));
        
        // allocate memory in each GPU
        for (dev = 0; dev < deviceCount; dev++){
            cudaSetDevice(dev);
            
            cudaMalloc((void**)&d_image[dev]    , mem_img_each_GPU);
            cudaMemset(d_image[dev],0,mem_img_each_GPU);
            cudaMalloc((void**)&d_dimgTV[dev]   , mem_img_each_GPU);
            cudaMalloc((void**)&d_norm2[dev]    , slices_per_split*mem_slice_image);
            cudaMalloc((void**)&d_norm2aux[dev] , mem_auxiliary);
            cudaCheckErrors("Malloc  error");
            
            
        }
        
        float* buffer;
        if(splits>1){
            mexWarnMsgIdAndTxt("minimizeTV:POCS_TV:Image_split","Your image can not be fully split between the available GPUs. The computation of minTV will be significantly slowed due to the image size.");
        }else{
            buffer=(float*)malloc(image_size[0]*image_size[1]*2*sizeof(float));
        }
        
        // For the reduction
        
        float* sumnorm2=(float*)malloc(deviceCount*sizeof(float));
        
        unsigned int curr_slices;
        for(unsigned int i=0;i<maxIter;i++){
            
            for(unsigned int sp=0;sp<splits;sp++){
                // For each iteration we need to comptue all the image. The ordering of these loops
                // need to be like this due to the boudnign layers between slpits. If more than 1 split is needed
                // for each GPU then there is no other way that taking the entire memory out of GPU and putting it back.
                // If the memory can be shared ebtween GPUs fully without extra splits, then there is an easy way of syncronizing the memory
                
                
                // Copy image to memory
                size_t linear_idx_start;
                
                for (dev = 0; dev < deviceCount; dev++){
                    curr_slices=((sp*deviceCount+dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*(sp*deviceCount+dev);
                    linear_idx_start=image_size[0]*image_size[1]*slices_per_split*(sp*deviceCount+dev);
                    
                    cudaSetDevice(dev);
                    cudaMemcpy((void**)&d_image[dev]+image_size[0]*image_size[1]*2, &img[linear_idx_start], image_size[0]*image_size[1]*curr_slices*sizeof(float), cudaMemcpyHostToDevice);
                    
                    // if its not the first, copy also the intersection buffer.
                    if(sp*deviceCount+dev){
                        cudaMemcpy((void**)&d_image[dev], &img[linear_idx_start-image_size[0]*image_size[1]*2], image_size[0]*image_size[1]*2*sizeof(float), cudaMemcpyHostToDevice);
                    }
                    cudaCheckErrors("Memcpy failure");
                }
                // if we need to split and its not the first iteration, tehn we need to copy from Host memory the previosu result.
                if (sp>1 & i>0){
                    curr_slices=((sp*deviceCount+dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*(sp*deviceCount+dev);
                    linear_idx_start=image_size[0]*image_size[1]*slices_per_split*(sp*deviceCount+dev);
                    
                    cudaSetDevice(dev);
                    cudaMemcpy((void**)&d_image[dev]+image_size[0]*image_size[1]*2, &dst[linear_idx_start], image_size[0]*image_size[1]*curr_slices*sizeof(float), cudaMemcpyHostToDevice);
                    if(sp*deviceCount+dev){
                        cudaMemcpy((void**)&d_image[dev], &dst[linear_idx_start-image_size[0]*image_size[1]*2], image_size[0]*image_size[1]*2*sizeof(float), cudaMemcpyHostToDevice);
                    }
                    cudaCheckErrors("Memcpy failure on multi split");
                    
                }
                
                
                // For the gradient
                dim3 blockGrad(10, 10, 10);
                dim3 gridGrad((image_size[0]+blockGrad.x-1)/blockGrad.x, (image_size[1]+blockGrad.y-1)/blockGrad.y, (image_size[2]+blockGrad.z-1)/blockGrad.z);
                
                for (dev = 0; dev < deviceCount; dev++){
                    cudaSetDevice(dev);
                    curr_slices=((sp*deviceCount+dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*(sp*deviceCount+dev);
                    // Compute the gradient of the TV norm
                    gradientTV<<<gridGrad, blockGrad>>>(d_image[dev],d_dimgTV[dev],curr_slices+2, image_size[1],image_size[0]);
                    cudaCheckErrors("Gradient");
                    
                }
//             cudaMemcpy(dst, d_dimgTV, mem_size_image, cudaMemcpyDeviceToHost);
                
                for (dev = 0; dev < deviceCount; dev++){
                    cudaSetDevice(dev);
                    curr_slices=((sp*deviceCount+dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*(sp*deviceCount+dev);
                    // no need to copy the 2 aux slices here
                    cudaMemcpyAsync(d_norm2[dev], d_dimgTV[dev]+image_size[0]*image_size[1]*2, image_size[0]*image_size[1]*curr_slices*sizeof(float), cudaMemcpyDeviceToDevice);
                    cudaCheckErrors("Copy from gradient call error");
                }
                // Compute the L2 norm of the gradint. For that, reduction is used.
                //REDUCE
                for (dev = 0; dev < deviceCount; dev++){
                    cudaSetDevice(dev);
                    curr_slices=((sp*deviceCount+dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*(sp*deviceCount+dev);
                    
                    total_pixels=curr_slices*image_size[0]*image_size[1];
                    
                    size_t dimblockRed = MAXTHREADS;
                    size_t dimgridRed = (total_pixels + MAXTHREADS - 1) / MAXTHREADS;
                    reduceNorm2 << <dimgridRed, dimblockRed, MAXTHREADS*sizeof(float) >> >(d_norm2[dev], d_norm2aux[dev], total_pixels);
                    //cudaCheckErrors("reduce1");
                    if (dimgridRed > 1) {
                        reduceSum << <1, dimblockRed, MAXTHREADS*sizeof(float) >> >(d_norm2aux[dev], d_norm2[dev], dimgridRed);
                        //cudaCheckErrors("reduce2");
                        cudaMemcpyAsync(&sumnorm2[dev], d_norm2[dev], sizeof(float), cudaMemcpyDeviceToHost);
                        //cudaCheckErrors("cudaMemcpy");
                        
                    }
                    else {
                        cudaMemcpyAsync(&sumnorm2[dev], d_norm2aux[dev], sizeof(float), cudaMemcpyDeviceToHost);
                        //cudaCheckErrors("cudaMemcpy");
                    }
                }
                cudaDeviceSynchronize();
                cudaCheckErrors("TV gradient and reduction error");
                
                float totalsum=0;
                // this is CPU code
                for (dev = 0; dev < deviceCount; dev++){
                    totalsum+=sumnorm2[dev];
                }
                
                for (dev = 0; dev < deviceCount; dev++){
                    cudaSetDevice(dev);
                    curr_slices=((sp*deviceCount+dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*(sp*deviceCount+dev);
                    total_pixels=curr_slices*image_size[0]*image_size[1];
                    //NOMRALIZE
                    //in a Tesla, maximum blocks =15 SM * 4 blocks/SM
                    divideArrayScalar  <<<60,MAXTHREADS>>>(d_dimgTV[dev]+image_size[0]*image_size[1]*2,sqrt(totalsum),total_pixels);
                    //cudaCheckErrors("Division error");
                    //MULTIPLY HYPERPARAMETER
                    multiplyArrayScalar<<<60,MAXTHREADS>>>(d_dimgTV[dev]+image_size[0]*image_size[1]*2,alpha,   total_pixels);
                }
                cudaDeviceSynchronize();
                cudaCheckErrors("Scalar operations error");
                
                //SUBSTRACT GRADIENT
                //////////////////////////////////////////////
                for (dev = 0; dev < deviceCount; dev++){
                    cudaSetDevice(dev);
                    curr_slices=((sp*deviceCount+dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*(sp*deviceCount+dev);
                    total_pixels=curr_slices*image_size[0]*image_size[1];
                    
                    substractArrays<<<60,MAXTHREADS>>>(d_image[dev]+image_size[0]*image_size[1]*2,d_dimgTV[dev]+image_size[0]*image_size[1]*2, total_pixels);
                }
                
                // Syncronize mathematics, make sure bounding pixels are correct
                
                if(splits==1){
                    for(dev=0; dev<deviceCount-1;dev++){
                        cudaSetDevice(dev);
                        cudaMemcpy(buffer, d_image[dev]+slices_per_split, image_size[0]*image_size[1]*2*sizeof(float), cudaMemcpyDeviceToHost);
                        cudaSetDevice(dev+1);
                        cudaMemcpy(d_image[dev+1],buffer, image_size[0]*image_size[1]*2*sizeof(float), cudaMemcpyHostToDevice);
                    }
                }else{
                    // We need to take it out :(
                    for(dev=0; dev<deviceCount;dev++){
                        cudaSetDevice(dev);
                        
                        curr_slices=((sp*deviceCount+dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*(sp*deviceCount+dev);
                        total_pixels=curr_slices*image_size[0]*image_size[1];
                        cudaMemcpy(dst+slices_per_split*(sp*deviceCount+dev), d_image[dev]+image_size[0]*image_size[1]*2,total_pixels*sizeof(float), cudaMemcpyDeviceToHost);
                    }
                }
                cudaDeviceSynchronize();
                cudaCheckErrors("Memory gather error");
                
            }
            
        }
        // If there has not been splits, we still have data in memory
        if(splits==1){
            for(dev=0; dev<deviceCount;dev++){
                cudaSetDevice(dev);
                
                curr_slices=((dev+1)*slices_per_split<image_size[2])?  slices_per_split:  image_size[2]-slices_per_split*dev;
                total_pixels=curr_slices*image_size[0]*image_size[1];
                cudaMemcpy(dst+slices_per_split*dev, d_image[dev]+image_size[0]*image_size[1]*2,total_pixels*sizeof(float), cudaMemcpyDeviceToHost);
            }
        }
        cudaCheckErrors("Copy result back");
        
        for(dev=0; dev<deviceCount;dev++){
            cudaSetDevice(dev);
            cudaFree(d_image[dev]);
            cudaFree(d_norm2aux[dev]);
            cudaFree(d_dimgTV[dev]);
            cudaFree(d_norm2[dev]);
        }
        cudaCheckErrors("Memory free");
        cudaDeviceReset();
    }
    
