# FMCOMMS2/AD9361 Testbench Architecture

This document describes the testbench architecture for the FMCOMMS2/AD9361 HDL reference design, including the Unit Under Test (UUT), stimulus generation, and response analysis.

## Overall System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              TEST HARNESS                                    │
│  ┌─────────────┐    ┌──────────────────────────────────────────────────┐   │
│  │  AXI VIP    │    │              FMCOMMS2 Block Design (UUT)         │   │
│  │  (Master)   │───▶│  ┌─────────┐  ┌──────┐  ┌──────┐  ┌─────────┐   │   │
│  └─────────────┘    │  │ AXI     │  │ TX   │  │ FIFO │  │ AD9361  │   │   │
│                     │  │ AD9361  │◀─│ DMA  │◀─│      │◀─│ upack   │   │   │
│  ┌─────────────┐    │  │         │  └──────┘  └──────┘  └─────────┘   │   │
│  │  DDR VIP    │    │  │         │                                     │   │
│  │  (Memory)   │◀──▶│  │         │  ┌──────┐  ┌──────┐  ┌─────────┐   │   │
│  └─────────────┘    │  │         │─▶│ RX   │─▶│ FIFO │─▶│ AD9361  │   │   │
│                     │  └─────────┘  │ DMA  │  │      │  │ pack    │   │   │
│  ┌─────────────┐    │               └──────┘  └──────┘  └─────────┘   │   │
│  │  CLK VIP    │    └──────────────────────────────────────────────────┘   │
│  │  (SSI CLK)  │───────────────────────────────────────────────────────────│
│  └─────────────┘                                                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                    LVDS LOOPBACK   │  (TX outputs → RX inputs)
                                    ▼
                    ┌───────────────────────────────┐
                    │  tx_data_out_p/n → rx_data_in_p/n
                    │  tx_frame_out_p/n → rx_frame_in_p/n
                    │  tx_clk_out → rx_clk_in
                    └───────────────────────────────┘
```

## Unit Under Test (UUT)

The UUT is the complete FMCOMMS2 block design (`fmcomms2_bd.tcl`) which implements a full AD9361 data path:

### Core Components

| Component | Function | Key Parameters |
|-----------|----------|----------------|
| `axi_ad9361` | AD9361 interface IP | LVDS mode, internal PLL, PN generators |
| `axi_ad9361_dac_dma` | TX DMA controller | Cyclic mode support, AXI4 master |
| `axi_ad9361_adc_dma` | RX DMA controller | AXI4 master to DDR |
| `util_ad9361_adc_fifo` | RX FIFO buffer | Clock domain crossing |
| `util_ad9361_dac_fifo` | TX FIFO buffer | Clock domain crossing |
| `util_ad9361_adc_pack` | RX channel packer | Combines I/Q channels |
| `util_ad9361_dac_upack` | TX channel unpacker | Splits I/Q channels |

### Data Flow

**TX Path (DDR → RF):**
```
DDR Memory → TX DMA → upack → TX FIFO → axi_ad9361 → LVDS outputs
```

**RX Path (RF → DDR):**
```
LVDS inputs → axi_ad9361 → RX FIFO → pack → RX DMA → DDR Memory
```

## Test Harness (`system_tb.sv`)

The test harness instantiates the UUT and implements external loopback:

```systemverilog
module system_tb();
  wire [5:0] tx_data_out_n;
  wire [5:0] tx_data_out_p;

  `TEST_PROGRAM test();

  test_harness `TH (
    .rx_data_in_n (tx_data_out_n),    // Loopback: TX → RX
    .rx_data_in_p (tx_data_out_p),
    .rx_frame_in_n (tx_frame_out_n),
    .rx_frame_in_p (tx_frame_out_p),
    // ...
  );

  assign rx_clk_in_n = ~ssi_clk;
  assign rx_clk_in_p = ssi_clk;
endmodule
```

### Key Features

- **External Loopback**: TX LVDS outputs connected directly to RX LVDS inputs
- **Clock Generation**: SSI clock VIP generates 250 MHz data clock
- **TDD Disabled**: `tdd_sync_i` tied to 0, `up_enable` and `up_txnrx` tied to 1

## LVDS Interface Details

### Loopback Implementation

The testbench does **not** use any custom behavioral models or VIPs for the LVDS interface. The loopback is implemented through direct wire connections in `system_tb.sv` (lines 52-53, 62-63):

```systemverilog
wire [5:0] tx_data_out_n;   // Line 40 - local wires
wire [5:0] tx_data_out_p;   // Line 41

test_harness `TH (
    .rx_data_in_n (tx_data_out_n),   // Line 52 - loopback: same wire
    .rx_data_in_p (tx_data_out_p),   // Line 53 - loopback: same wire
    // ...
    .tx_data_out_n (tx_data_out_n),  // Line 62 - TX drives wire
    .tx_data_out_p (tx_data_out_p),  // Line 63 - TX drives wire
);
```

The same wires are connected to both TX outputs and RX inputs - whatever axi_ad9361 drives on TX is immediately visible on RX.

### Signal Chain Inside axi_ad9361

The UUT uses real Xilinx primitives (from UNISIM library) for simulation:

**TX Path** (`axi_ad9361_lvds_if.v` lines 488-510):
```
tx_data[47:0] → tx_data_sel mux → tx_data_0/tx_data_1
                                        │
                                        ▼
                              ad_data_out (×6 channels)
                                        │
                                        ▼
                              ODDR (DDR output register)
                                        │
                                        ▼
                              OBUFDS (LVDS output buffer)
                                        │
                                        ▼
                              tx_data_out_p/n[5:0]
```

**RX Path** (`axi_ad9361_lvds_if.v` lines 442-463):
```
rx_data_in_p/n[5:0]
        │
        ▼
  IBUFDS (LVDS input buffer)
        │
        ▼
  IDELAYE2/3 (optional delay line)
        │
        ▼
  IDDR (DDR input register)
        │
        ▼
  rx_data_0_s/rx_data_1_s → frame delineation → adc_data[47:0]
```

### LVDS Primitive Modules

| Module | File | Function |
|--------|------|----------|
| `ad_data_out` | `library/xilinx/common/ad_data_out.v` | ODDR → (ODELAY) → OBUFDS |
| `ad_data_in` | `library/xilinx/common/ad_data_in.v` | IBUFDS → (IDELAY) → IDDR |
| `axi_ad9361_lvds_if` | `library/axi_ad9361/xilinx/axi_ad9361_lvds_if.v` | Data mux, frame generation, delineation |

### Why No Behavioral Models Are Needed

1. **Direct wire loopback** - TX outputs connect directly to RX inputs via Verilog wires
2. **Xilinx simulation primitives** - IBUFDS, OBUFDS, IDDR, ODDR are provided by Vivado's UNISIM library
3. **CLK VIP provides timing** - The 250 MHz `ssi_clk` drives both RX sample clock and internal line clock

The Xilinx primitives handle the DDR timing relationship between rising/falling edge data and produce valid waveforms that are captured correctly on the RX side without external models.

## Test Program (`test_program.sv`)

The test program contains four distinct test cases:

---

### Test 1: Sanity Test (`sanity_test`)

**Purpose**: Basic register access verification

**Stimulus**:
```systemverilog
axi_read_v(`AXI_AD9361_BA + 32'h40, axi_rdata);  // Read RSTN register
axi_read_v(`AXI_AD9361_BA + 32'h44, axi_rdata);  // Read REG_ID register
```

**Expected Response**:
- `0x40`: Reset register readable
- `0x44`: Version ID returns expected value

**Analysis**: Confirms AXI bus connectivity and basic register access to the axi_ad9361 IP.

---

### Test 2: PN Test (`pn_test`)

**Purpose**: Data integrity verification through complete TX→RX loopback using PN9 sequences

**Stimulus Sequence**:

1. **Configure PN9 Generator (TX side)**:
```systemverilog
axi_write(`AXI_AD9361_BA + 32'h4418, 32'h6);  // TX1 I: PN9 mode
axi_write(`AXI_AD9361_BA + 32'h4458, 32'h6);  // TX1 Q: PN9 mode
axi_write(`AXI_AD9361_BA + 32'h4498, 32'h6);  // TX2 I: PN9 mode
axi_write(`AXI_AD9361_BA + 32'h44d8, 32'h6);  // TX2 Q: PN9 mode
```

2. **Configure PN9 Checker (RX side)**:
```systemverilog
axi_write(`AXI_AD9361_BA + 32'h4048, 32'h1);  // RX1 I: PN9 monitor
axi_write(`AXI_AD9361_BA + 32'h40c8, 32'h1);  // RX1 Q: PN9 monitor
axi_write(`AXI_AD9361_BA + 32'h4148, 32'h1);  // RX2 I: PN9 monitor
axi_write(`AXI_AD9361_BA + 32'h41c8, 32'h1);  // RX2 Q: PN9 monitor
```

3. **Take out of reset and wait**:
```systemverilog
axi_write(`AXI_AD9361_BA + 32'h40, 32'h3);    // Enable TX and RX
#1us;                                          // Wait for PN sync
```

4. **Read and check PN status**:
```systemverilog
axi_read_v(`AXI_AD9361_BA + 32'h4054, axi_rdata);  // RX1 I status
// Check bits [1:0]: 00 = PN sync OK, 01 = OOS, 10 = errors
```

**Expected Response**:
- All PN status registers should show `0x0` (synchronized, no errors)
- OOS (Out Of Sync) bit = 0
- PN Error bit = 0

**Analysis**: This test verifies:
- LVDS serializer/deserializer alignment
- Clock domain crossing integrity
- Data path bit integrity through complete loopback

---

### Test 3: DDS Test (`dds_test`)

**Purpose**: Verify DDS tone generation and data path using DMA transfers

**Stimulus Sequence**:

1. **Configure DDS (CORDIC tone generator)**:
```systemverilog
// Set DDS frequency and scale for each channel
axi_write(`AXI_AD9361_BA + 32'h4424, 32'h...);  // TX1 I: freq/phase
axi_write(`AXI_AD9361_BA + 32'h4428, 32'h...);  // TX1 I: scale
// ... repeat for all channels
```

2. **Configure and start RX DMA**:
```systemverilog
axi_write(`RX_DMA_BA + 32'h400, 32'h1);         // Enable DMA
axi_write(`RX_DMA_BA + 32'h40c, 32'h...);       // Set dest address
axi_write(`RX_DMA_BA + 32'h418, `RX_LENGTH-1);  // Set transfer length
axi_write(`RX_DMA_BA + 32'h408, 32'h1);         // Start transfer
```

3. **Wait for completion and verify**:
```systemverilog
// Poll DMA status until complete
// Read captured samples from DDR VIP memory
// Verify DDS waveform characteristics
```

**Expected Response**:
- DMA transfer completes successfully
- Captured data shows expected DDS tone pattern
- Memory contents match expected sinusoidal values

**Analysis**: This test verifies:
- DDS/CORDIC tone generation in TX path
- Complete data flow from DDS → LVDS → RX → DMA → DDR
- DMA controller operation
- Memory interface functionality

---

### Test 4: DMA Test (`dma_test`)

**Purpose**: Full bidirectional DMA transfer verification with known data patterns

**Stimulus Sequence**:

1. **Preload TX data into DDR**:
```systemverilog
for (int i = 0; i < `TX_LENGTH/8; i++) begin
  env.ddr_axi_agent.mem_model.backdoor_memory_write_4byte(
    `DDR_BA + i*8,
    (((i*2)+1) << 16) | (i*2),  // Known pattern
    4'hF);
end
```

2. **Configure TX DMA (cyclic mode)**:
```systemverilog
axi_write(`TX_DMA_BA + 32'h400, 32'h1);         // Enable
axi_write(`TX_DMA_BA + 32'h40c, `DDR_BA);       // Source address
axi_write(`TX_DMA_BA + 32'h418, `TX_LENGTH-1);  // Length
axi_write(`TX_DMA_BA + 32'h41c, 32'h1);         // Cyclic mode
axi_write(`TX_DMA_BA + 32'h408, 32'h1);         // Start
```

3. **Configure and start RX DMA**:
```systemverilog
axi_write(`RX_DMA_BA + 32'h400, 32'h1);         // Enable
axi_write(`RX_DMA_BA + 32'h40c, `DDR_BA + 32'h2000);  // Different dest
axi_write(`RX_DMA_BA + 32'h418, `RX_LENGTH-1);  // Length
axi_write(`RX_DMA_BA + 32'h408, 32'h1);         // Start
```

4. **Wait and verify received data**:
```systemverilog
// Wait for RX DMA complete
// Read back from DDR and compare with TX pattern
// Allow for pipeline latency offset
```

**Expected Response**:
- TX DMA reads pattern from DDR
- Data flows through complete TX→LVDS→RX→DMA path
- RX DMA writes to DDR at different address
- Received data matches transmitted pattern (with possible offset)

**Analysis**: This test verifies:
- Complete bidirectional data path
- DMA read and write operations
- Data integrity through entire system
- Memory arbitration (simultaneous TX read and RX write)

---

## Key APIs and Register Map

### AXI AD9361 Registers

| Offset | Register | Description |
|--------|----------|-------------|
| 0x0040 | RSTN | Reset control |
| 0x0044 | REG_ID | Version/ID |
| 0x4048 | ADC_CHAN_CNTRL_1 (Ch0) | RX channel 0 PN control |
| 0x4054 | ADC_CHAN_STATUS (Ch0) | RX channel 0 PN status |
| 0x4418 | DAC_CHAN_CNTRL_7 (Ch0) | TX channel 0 data select |
| 0x4424 | DAC_DDS_INCR (Ch0) | DDS frequency word |
| 0x4428 | DAC_DDS_SCALE (Ch0) | DDS amplitude scale |

### DMA Registers

| Offset | Register | Description |
|--------|----------|-------------|
| 0x400 | DMACR | DMA control register |
| 0x408 | DMASR | Start/status register |
| 0x40C | DEST/SRC_ADDR | Transfer address |
| 0x418 | X_LENGTH | Transfer length |
| 0x41C | FLAGS | Cyclic mode, etc. |

## Test Environment Setup

The test environment uses ADI's simulation framework:

```systemverilog
environment env;
initial begin
  env = new(`TH.`SYS_CLK.inst.IF,   // System clock VIP
            `TH.`DMA_CLK.inst.IF,   // DMA clock VIP
            `TH.`DDR_CLK.inst.IF,   // DDR clock VIP
            `TH.`SYS_RST.inst.IF,   // Reset VIP
            `TH.`MNG_AXI.inst.IF,   // AXI manager VIP
            `TH.`DDR_AXI.inst.IF);  // DDR AXI VIP
  // ...
end
```

## Running the Tests

Use the `build_fmcomms2_tests.tcl` script to build and run:

```tcl
source build_fmcomms2_tests.tcl
```

Successful completion shows:
```
Test complete! 1
```

A return value of `1` indicates all tests passed.
