// mandel_constants.vh

// If we have not included this file before,
// this symbol _mandel_constants_vh_ is not defined.

`ifndef _mandel_constants_vh_
   `define _mandel_constants_vh_

   // Number of mandelbrot engines to instantiate
   `define NUM_PROC 7
   // Number of bits in engine address bus.
   `define E_ADDR_WIDTH $clog2(`NUM_PROC)
   `define MAX_ITERATIONS 511  // Do not exceed 65535. Counting happens in engine.ItrCounter[15:0].
   `define OVERRENDER_ITERATIONS 8191
   `define OVERRENDER_DEEP_ITERATIONS 32767
   // Override from the Quartus command line/QSF for a reproducible baseline.
   `ifndef USE_INTERLEAVED_ENGINE
      `define USE_INTERLEAVED_ENGINE 1
   `endif
`endif
