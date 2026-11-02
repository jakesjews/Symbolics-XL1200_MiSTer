CXX ?= c++
CXXFLAGS ?= -std=c++17 -O2 -g -Wall -Wno-unused-parameter
SRCS = cpu_core.cpp cpu_insn.cpp machine.cpp fpa.cpp nvram.cpp pit.cpp scsi.cpp i82586.cpp ioboard.cpp console.cpp snapshot.cpp main.cpp
OBJS = $(SRCS:%.cpp=build/%.o)

xlemu: $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS)

build/%.o: %.cpp cpu.h ivory.h machine.h fpa.h nvram.h pit.h scsi.h i82586.h ioboard.h console.h keyboard.h opcodes.inc snapshot.h
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -rf build xlemu
