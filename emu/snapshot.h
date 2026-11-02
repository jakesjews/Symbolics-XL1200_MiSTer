// A snapshot of the whole machine (processor, memory, devices) to a file, and
// back: a run can stop just before the instruction under study and every
// experiment resume from there in a second instead of replaying a boot.
// The disk image is not in the file: the run writes to the image it was given
// (-d), so the caller keeps a copy of that image from the same moment (xlemu
// -W copies it to FILE.disk) and resumes on a copy of the copy.
#pragma once
#include <string>
class Ivory;
class Machine;
struct Snapshot {
  static bool save(const std::string& path, Ivory& cpu, Machine& m);
  static bool load(const std::string& path, Ivory& cpu, Machine& m);
  struct V;   // the field visitor, in snapshot.cpp
};
