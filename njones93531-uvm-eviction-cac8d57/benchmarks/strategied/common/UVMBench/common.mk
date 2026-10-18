all:
	nvcc -O3 ${CUFILES} ${DEF} -o ${EXECUTABLE} -arch=native -Xcompiler "-Wall -Wextra -O3 -fopenmp"

clean:
	rm -f *~ *.exe
