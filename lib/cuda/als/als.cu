#include <unistd.h>

#include <cuda_runtime.h>
#include "cublas_v2.h"

#include "buffalo/cuda/utils.cuh"
#include "buffalo/cuda/als/als.hpp"


namespace cuda_als{

using std::invalid_argument;
using namespace cuda_buffalo;

__global__ void least_squares_cg_kernel(const int dim, const int vdim, 
        const int rows, const int op_rows, 
        float* P, const float* Q, const float* FF, float* loss_nume, float* loss_deno,
        const int start_x, const int next_x,
        const int64_t* indptr, const int* keys, const float* vals, 
        const float alpha, const float reg, const bool adaptive_reg, const float cg_tolerance,
        const int num_cg_max_iters, const bool compute_loss,
        const float eps, const bool axis){
    extern __shared__ float shared_memory[];
    float* Ap = &shared_memory[0];
    float* r = &shared_memory[vdim];
    float* p = &shared_memory[2*vdim];
    
    int64_t shift = start_x == 0? 0: indptr[start_x - 1];
    for (int row=blockIdx.x + start_x; row<next_x; row+=gridDim.x){
        float* _P = &P[(row+start_x)*vdim];

        if (indptr[row] == indptr[row + 1]) {
            _P[threadIdx.x] = 0;
            continue;
        }
        int beg = indptr[row] - shift;
        int end = indptr[row + 1] - shift;
        // set adaptive regularization coefficient
        float ada_reg = adaptive_reg? indptr[row + 1] - indptr[row]: 1.0;
        ada_reg *= reg;

        float tmp = 0.0;
        // not necessary to compute vdim times
        for (int d=0; d<dim; ++d)
            tmp -= _P[d] * FF[d * vdim + threadIdx.x];
        Ap[threadIdx.x] = -tmp;

        // compute loss on negative samples (only item side)
        if (compute_loss and axis){
            float _dot = dot(_P, Ap);
            if (threadIdx.x == 0){
                loss_nume[blockIdx.x] += _dot;
                loss_deno[blockIdx.x] += op_rows;
            }
        }

        tmp -= _P[threadIdx.x] * ada_reg;

        for (int idx=beg; idx<end; ++idx){
            const float* _Q = &Q[keys[idx] * vdim];
            const float v = vals[idx];
            float _dot = dot(_P, _Q);
            // compute loss on positive samples (only item side)
            if (compute_loss and axis and threadIdx.x == 0){
                loss_nume[blockIdx.x] -= _dot * _dot;
                loss_nume[blockIdx.x] += (1.0 + v * alpha) * (_dot - 1) * (_dot - 1);
                loss_deno[blockIdx.x] += v * alpha;
            }
            tmp += (1 + alpha * v * (1 - _dot)) * _Q[threadIdx.x];
        }
        p[threadIdx.x] = r[threadIdx.x] = tmp;

        float rsold = dot(r, r);
        // early stopping
        if (rsold < cg_tolerance){
            // compute loss on regularization (both user and item side)
            if (compute_loss){
                float _dot = dot(_P, _P);
                if (threadIdx.x == 0)
                    loss_nume[blockIdx.x] += _dot * ada_reg;
            }
            continue;
        }

        // iterate cg
        for (int it=0; it<num_cg_max_iters; ++it){
            Ap[threadIdx.x] = ada_reg * p[threadIdx.x];
            for (int d=0; d<dim; ++d){
                Ap[threadIdx.x] += p[d] * FF[d * vdim + threadIdx.x];
            }
            for (int idx=beg; idx<end; ++idx){
                const float* _Q = &Q[keys[idx] * vdim];
                const float v = vals[idx];
                float _dot = dot(p, _Q);
                Ap[threadIdx.x] += v * alpha * _dot * _Q[threadIdx.x];
            }
            float alpha = rsold / (dot(p, Ap) + eps);
            _P[threadIdx.x] += alpha * p[threadIdx.x];
            r[threadIdx.x] -= alpha * Ap[threadIdx.x];
            float rsnew = dot(r, r);
            if (rsnew < cg_tolerance) break;
            p[threadIdx.x] = r[threadIdx.x] + (rsnew / (rsold + eps)) * p[threadIdx.x];
            rsold = rsnew;
            __syncthreads();
        }

        // compute loss on regularization (both user and item side)
        if (compute_loss){
            float _dot = dot(_P, _P);
            if (threadIdx.x == 0)
                loss_nume[blockIdx.x] += _dot * ada_reg;
        }
        
        if (isnan(rsold)){
            if (threadIdx.x == 0)
                printf("Warning NaN detected in row %d of %d\n", row, rows);
            _P[threadIdx.x] = 0.0;
        }
    }
}

CuALS::CuALS(){
    opt_setted_ = false, initialized_ = false, ph_setted_ = false;
    CHECK_CUDA(cudaGetDevice(&devId_));
    CHECK_CUDA(cudaDeviceGetAttribute(&mp_cnt_, cudaDevAttrMultiProcessorCount, devId_));
    block_cnt_ = 128 * mp_cnt_;
}

CuALS::~CuALS(){
    // destructor
    CHECK_CUBLAS(cublasDestroy(blas_handle_));

    // free memory of utility variables
    if (opt_setted_){
        CHECK_CUDA(cudaFree(devFF_)); devFF_ = nullptr;
        if (compute_loss_){
            free(hostLossNume_);
            free(hostLossDeno_);
            CHECK_CUDA(cudaFree(devLossNume_));
            CHECK_CUDA(cudaFree(devLossDeno_));
        }
    }

    // free memory of embedding matrix
    if (initialized_){
        CHECK_CUDA(cudaFree(devP_));
        CHECK_CUDA(cudaFree(devQ_));
        devP_ = nullptr, devQ_ = nullptr;
        hostP_ = nullptr, hostQ_ = nullptr;
    }

    // free memory of placeholders
    if (ph_setted_){
        CHECK_CUDA(cudaFree(lindptr_));
        CHECK_CUDA(cudaFree(rindptr_));
        CHECK_CUDA(cudaFree(keys_));
        CHECK_CUDA(cudaFree(vals_));
    }
}

bool CuALS::parse_option(std::string opt_path, Json& j){
    std::ifstream in(opt_path.c_str());
    if (not in.is_open()) {
        return false;
    }

    std::string str((std::istreambuf_iterator<char>(in)),
               std::istreambuf_iterator<char>());
    std::string err_cmt;
    auto _j = Json::parse(str, err_cmt);
    if (not err_cmt.empty()) {
        return false;
    }
    j = _j;
    return true;
}

bool CuALS::init(std::string opt_path){
    // parse options
    bool ok = parse_option(opt_path, opt_);
    if (ok){
        // set options
        compute_loss_ = opt_["compute_loss_on_training"].bool_value();
        adaptive_reg_ = opt_["adaptive_reg"].bool_value();

        dim_ = opt_["d"].int_value();
        num_cg_max_iters_ = opt_["num_cg_max_iters"].int_value();
         
        alpha_ = opt_["alpha"].number_value();
        reg_u_ = opt_["reg_u"].number_value();
        reg_i_ = opt_["reg_i"].number_value();
        cg_tolerance_ = opt_["cg_tolerance"].number_value();
        eps_ = opt_["eps"].number_value();
        
        // virtual dimension
        vdim_ = (dim_ / WARP_SIZE) * WARP_SIZE;
        if (dim_ % WARP_SIZE > 0) vdim_ += WARP_SIZE;
        CHECK_CUDA(cudaMalloc(&devFF_, sizeof(float)*vdim_*vdim_));
        CHECK_CUBLAS(cublasCreate(&blas_handle_));
        
        if (compute_loss_){
            hostLossNume_ = (float*) malloc(sizeof(float)*block_cnt_);
            hostLossDeno_ = (float*) malloc(sizeof(float)*block_cnt_);
            CHECK_CUDA(cudaMalloc(&devLossNume_, sizeof(float)*block_cnt_));
            CHECK_CUDA(cudaMalloc(&devLossDeno_, sizeof(float)*block_cnt_));
        }
        opt_setted_ = true;
    }
    return ok;
}

void CuALS::set_placeholder(int64_t* lindptr, int64_t* rindptr, int batch_size){
     
    CHECK_CUDA(cudaMalloc(&lindptr_, sizeof(int64_t)*(P_rows_)));
    CHECK_CUDA(cudaMalloc(&rindptr_, sizeof(int64_t)*(Q_rows_)));
    CHECK_CUDA(cudaMemcpy(lindptr_, lindptr, sizeof(int)*(P_rows_), 
               cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(rindptr_, rindptr, sizeof(int)*(Q_rows_), 
               cudaMemcpyHostToDevice));

    CHECK_CUDA(cudaMalloc(&keys_, sizeof(int)*batch_size));
    CHECK_CUDA(cudaMalloc(&vals_, sizeof(float)*batch_size));
    batch_size_ = batch_size;
    ph_setted_ = true;
}

void CuALS::initialize_model(
        float* P, int P_rows,
        float* Q, int Q_rows){
    // initialize parameters and send to gpu memory
    hostP_ = P;
    hostQ_ = Q;
    P_rows_ = P_rows;
    Q_rows_ = Q_rows;
    CHECK_CUDA(cudaMalloc(&devP_, sizeof(float)*P_rows_*vdim_));
    CHECK_CUDA(cudaMemcpy(devP_, hostP_, sizeof(float)*P_rows_*vdim_, 
               cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMalloc(&devQ_, sizeof(float)*Q_rows_*vdim_));
    CHECK_CUDA(cudaMemcpy(devQ_, hostQ_, sizeof(float)*Q_rows_*vdim_, 
               cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaDeviceSynchronize());
    initialized_ = true;
}

void CuALS::precompute(int axis){
    // precompute FF using cublas
    int op_rows = axis == 0? Q_rows_: P_rows_;
    float* opF = axis == 0? devQ_: devP_;
    float alpha = 1.0, beta = 0.0;
    CHECK_CUBLAS(cublasSgemm(blas_handle_, CUBLAS_OP_N, CUBLAS_OP_T,
                 vdim_, vdim_, op_rows, &alpha, 
                 opF, vdim_, opF, vdim_, &beta, devFF_, vdim_));
    CHECK_CUDA(cudaDeviceSynchronize());
}

void CuALS::synchronize(int axis, bool device_to_host){
    // synchronize parameters between cpu memory and gpu memory
    time_p beg_t, end_t;
    beg_t = get_now();
    float* devF = axis == 0? devP_: devQ_;
    float* hostF = axis == 0? hostP_: hostQ_;
    int rows = axis == 0? P_rows_: Q_rows_;
    if (device_to_host){
        CHECK_CUDA(cudaMemcpy(hostF, devF, sizeof(float)*rows*vdim_, 
                   cudaMemcpyDeviceToHost));
    } else{
        CHECK_CUDA(cudaMemcpy(devF, hostF, sizeof(float)*rows*vdim_, 
                   cudaMemcpyHostToDevice));
    }
    CHECK_CUDA(cudaDeviceSynchronize());
    end_t = get_now();
    double el = GetTimeDiff(beg_t, end_t);

    printf("elapsed: %.3f sec\n", el);
}

int CuALS::get_vdim(){
    return vdim_;
}

std::pair<double, double> CuALS::partial_update(int start_x, 
        int next_x,
        int* keys,
        float* vals,
        int axis){
    int thread_cnt = vdim_;
    size_t shared_memory_size = sizeof(float) * (3 * vdim_);
    int rows = axis == 0? P_rows_: Q_rows_;
    int op_rows = axis == 0? Q_rows_: P_rows_;
    float* P = axis == 0? devP_: devQ_;
    float* Q = axis == 0? devQ_: devP_;
    float reg = axis == 0? reg_u_: reg_i_;
    int64_t* indptr = axis == 0?  lindptr_: rindptr_; 
    time_p beg_t, end_t;
    beg_t = get_now();

    
    // copy data to gpu memory
    CHECK_CUDA(cudaMemcpy(keys_, keys, sizeof(int)*batch_size_, 
               cudaMemcpyHostToDevice));
    CHECK_CUDA(cudaMemcpy(vals_, vals, sizeof(float)*batch_size_, 
               cudaMemcpyHostToDevice));

    // set zeros for measuring losses
    if (compute_loss_){
        for (size_t i=0; i<block_cnt_; ++i){
            hostLossNume_[i] = 0;
            hostLossDeno_[i] = 0;
        }
        CHECK_CUDA(cudaMemcpy(devLossNume_, hostLossDeno_, sizeof(float)*block_cnt_, 
                   cudaMemcpyHostToDevice));
        CHECK_CUDA(cudaMemcpy(devLossDeno_, hostLossDeno_, sizeof(float)*block_cnt_, 
                   cudaMemcpyHostToDevice));
        
    } 
    CHECK_CUDA(cudaDeviceSynchronize());
    
    end_t = get_now();
    double el = GetTimeDiff(beg_t, end_t);
    beg_t = end_t;
    printf("elapsed for copy: %f sec\n", el);

    // compute least square
    least_squares_cg_kernel<<<block_cnt_, thread_cnt, shared_memory_size>>>(
            dim_, vdim_, rows, op_rows, P, Q, devFF_, devLossNume_, devLossDeno_, 
            start_x, next_x, indptr, keys_, vals_, alpha_, reg, adaptive_reg_,
            cg_tolerance_, num_cg_max_iters_, compute_loss_, eps_, axis);
    CHECK_CUDA(cudaDeviceSynchronize());
    
    end_t = get_now();
    el = GetTimeDiff(beg_t, end_t);
    beg_t = end_t;
    printf("elapsed for least square: %f sec\n", el);
   
    // accumulate losses
    double loss_nume = 0, loss_deno = 0;
    if (compute_loss_){
        CHECK_CUDA(cudaMemcpy(hostLossNume_, devLossNume_, sizeof(float)*block_cnt_, 
                   cudaMemcpyDeviceToHost));
        CHECK_CUDA(cudaMemcpy(hostLossDeno_, devLossDeno_, sizeof(float)*block_cnt_, 
                   cudaMemcpyDeviceToHost));
        CHECK_CUDA(cudaDeviceSynchronize());
        for (size_t i=0; i<block_cnt_; ++i){
            loss_nume += hostLossNume_[i];
            loss_deno += hostLossDeno_[i];
        }
    }
    end_t = get_now();
    el = GetTimeDiff(beg_t, end_t);
    beg_t = end_t;
    printf("elapsed for accumulating loss: %f sec\n", el);

    
    end_t = get_now();
    el = GetTimeDiff(beg_t, end_t);
    beg_t = end_t;
    printf("elapsed for free memory: %f sec\n", el);
    
    return std::make_pair(loss_nume, loss_deno);
}

} // namespace cuda_als