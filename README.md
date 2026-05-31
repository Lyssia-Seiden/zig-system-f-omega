# System F_omega

This repo contains my project for CMPTGCS 130e Computation via Types, Logic, and Topology.
This was originally a simple System F implementation
which I then added higher-kindedness to as my final project.
This may be built as a standalone Zig binary by a standard Zig toolchain, and is written in Zig 0.16.0.
The binary takes an input file,
parses it into a bare-bones IR,
typechecks that,
then evaluates it.
Several examples are provided in ./examples.
If you are Harlan looking to run this on CSIL,
I should have placed a compiled binary in this folder to run.

The syntax closely matches that of the mathematical notation
for System F_omega.
Note that I use both Λ for type abstraction
and :: for marking the kind of a variable,
which is not strictly necessary as one is sufficient to have an unambiguous grammar.

This implementation is surely buggy, 
including rather slapdash type equivalence checking at time of writing.
I believe I also have some mistakes in the memory management,
as this was my first time using Zig.

