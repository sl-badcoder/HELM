CXXFLAGS=-O3
CUDA_CXX=nvcc

cuda-stream: main.cpp CUDAStream.cu
	$(CUDA_CXX) -arch=native -std=c++11 $(CXXFLAGS) -DCUDA $^ $(EXTRA_FLAGS) -Xptxas "-v" -o $@ -Xcompiler "-Wall -Wextra -O3 -fopenmp"

.PHONY: clean
clean:
	rm -f cuda-stream
