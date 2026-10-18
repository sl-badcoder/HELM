#include <cuda_runtime.h>

#include <cstdlib>
#include <iostream>

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <size_GiB>\n";
        return 1;
    }

    double gib = std::stod(argv[1]);
    std::size_t bytes =
        static_cast<std::size_t>(gib * 1024.0 * 1024.0 * 1024.0);

    void* ptr = nullptr;

    cudaError_t err = cudaMalloc(&ptr, bytes);

    if (err != cudaSuccess) {
        std::cerr << "cudaMalloc failed: "
                  << cudaGetErrorString(err) << '\n';
        return 1;
    }

    // Touch the allocation.
    err = cudaMemset(ptr, 0, bytes);

    if (err != cudaSuccess) {
        std::cerr << "cudaMemset failed: "
                  << cudaGetErrorString(err) << '\n';
        cudaFree(ptr);
        return 1;
    }

    cudaDeviceSynchronize();

    std::cout << "Reserved " << gib << " GiB of VRAM.\n";
    std::cout << "Press Enter to release it...\n";

    std::cin.get();

    cudaFree(ptr);

    std::cout << "VRAM released.\n";
    return 0;
}