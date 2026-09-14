// Minimal soc_pkg for CW305 prototyping
// Removes Flash, PSRAM, FabricConfig, Fabric bus peripherals
// Keeps: SRAM + UART only (reduces OBI demux from 7 to 3 outputs)
package soc_pkg;

    localparam int unsigned HartId = 32'd0;
    localparam int unsigned BootAddr = 32'h1000_0080; // Boot from SRAM
    localparam int unsigned MtvecAddr = 32'h1000_0000;

    localparam int unsigned NumManagers = 2; // Instr, Data

    typedef enum int {
        ManagInstr = 0,
        ManagData  = 1
    } manage_outputs_e;

    typedef struct packed {
        logic [31:0] idx;
        logic [31:0] start_addr;
        logic [31:0] end_addr;
    } addr_map_rule_t;

    // Minimal peripheral map: Error(0), SRAM(1), UART(2)
    localparam bit [31:0] SramAddrOffset  = 32'h1000_0000;
    localparam bit [31:0] SramAddrRange   = 32'h0000_2000; // 8 KB

    localparam bit [31:0] Uart0AddrOffset = 32'h3000_0000;
    localparam bit [31:0] Uart0AddrRange  = 32'h0001_0000;

    localparam int unsigned NumPeriphRules = 2;
    localparam int unsigned NumPeriphs     = NumPeriphRules + 1;

    typedef enum int {
        PeriphError = 0,
        PeriphSram  = 1,
        PeriphUart0 = 2
    } periph_outputs_e;

    localparam addr_map_rule_t [NumPeriphRules-1:0] periph_addr_map = '{
        '{ idx: PeriphSram,  start_addr: SramAddrOffset, end_addr: SramAddrOffset + SramAddrRange },
        '{ idx: PeriphUart0, start_addr: Uart0AddrOffset, end_addr: Uart0AddrOffset + Uart0AddrRange }
    };

    localparam int unsigned NumPMARules = NumPeriphRules;

    localparam cv32e40x_pkg::pma_cfg_t pma_cfg [NumPMARules] = '{
        '{word_addr_low: SramAddrOffset>>2, word_addr_high: (SramAddrOffset+SramAddrRange)>>2, main: 1'b1, bufferable: 1'b1, cacheable: 1'b1, atomic: 1'b1},
        '{word_addr_low: Uart0AddrOffset>>2, word_addr_high: (Uart0AddrOffset+Uart0AddrRange)>>2, main: 1'b0, bufferable: 1'b0, cacheable: 1'b0, atomic: 1'b0}
    };

    localparam obi_pkg::obi_cfg_t SbrObiCfg = '{
        UseRReady: 1'b0, CombGnt: 1'b0, AddrWidth: 32, DataWidth: 32,
        IdWidth: 1, Integrity: 1'b0, BeFull: 1'b1, OptionalCfg: '0
    };

    localparam obi_pkg::obi_cfg_t MgrObiCfg = '{
        UseRReady: 1'b0, CombGnt: 1'b0, AddrWidth: 32, DataWidth: 32,
        IdWidth: 0, Integrity: 1'b0, BeFull: 1'b0, OptionalCfg: '0
    };

    typedef obi_pkg::obi_a_optional_t mgr_obi_a_optional_t;
    typedef obi_pkg::obi_r_optional_t mgr_obi_r_optional_t;
    typedef obi_pkg::obi_a_optional_t sbr_obi_a_optional_t;
    typedef obi_pkg::obi_r_optional_t sbr_obi_r_optional_t;

    `OBI_TYPEDEF_ALL(mgr_obi, MgrObiCfg)
    `OBI_TYPEDEF_ALL(sbr_obi, SbrObiCfg)

endpackage
