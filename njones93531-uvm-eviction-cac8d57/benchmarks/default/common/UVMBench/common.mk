all:
	nvcc -O3 ${CUFILES} ${DEF} -o ${EXECUTABLE} -arch=native -Xcompiler "-fopenmp"
clean:
	rm -f *~ *.exe
