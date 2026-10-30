CXX ?= c++
CXXFLAGS ?= -std=c++17 -O2 -g -Wall -Wno-unused-parameter
SRCS = cpu_core.cpp cpu_insn.cpp machine.cpp nvram.cpp pit.cpp scsi.cpp ioboard.cpp console.cpp main.cpp
OBJS = $(SRCS:%.cpp=build/%.o)

xlemu: $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS)

build/%.o: %.cpp cpu.h ivory.h machine.h nvram.h scsi.h ioboard.h console.h keyboard.h opcodes.inc
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -rf build xlemu
