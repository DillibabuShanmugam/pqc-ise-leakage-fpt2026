// tc_sram - Behavioral SRAM for open-source FPGA flow
// Replaces tc_sram_xilinx.sv (XPM macros) with inference-friendly Verilog

module tc_sram #(
    parameter int unsigned NumWords     = 32'd1024,
    parameter int unsigned DataWidth    = 32'd128,
    parameter int unsigned ByteWidth    = 32'd8,
    parameter int unsigned NumPorts     = 32'd2,
    parameter int unsigned Latency      = 32'd1,
    parameter              SimInit      = "none",
    parameter bit          PrintSimCfg  = 1'b0,
    parameter bit          AddrCheck    = 1'b0,
    parameter              ImplKey      = "none",
    parameter              MemInitFile  = ""
) (
    input  logic                                clk_i,
    input  logic                                rst_ni,
    input  logic  [NumPorts-1:0]                req_i,
    input  logic  [NumPorts-1:0]                we_i,
    input  logic  [NumPorts-1:0][$clog2(NumWords)-1:0] addr_i,
    input  logic  [NumPorts-1:0][DataWidth-1:0] wdata_i,
    input  logic  [NumPorts-1:0][DataWidth/ByteWidth-1:0] be_i,
    output logic  [NumPorts-1:0][DataWidth-1:0] rdata_o
);

    localparam int unsigned AddrWidth = $clog2(NumWords);
    localparam int unsigned NumBytes  = DataWidth / ByteWidth;

    (* ram_style = "block" *)
    reg [DataWidth-1:0] mem [0:NumWords-1];

    initial begin
        for (int i = 0; i < NumWords; i++)
            mem[i] = '0;
    end

    generate
        if (NumPorts == 1) begin : gen_sp
            reg [DataWidth-1:0] rdata_q;

            always @(posedge clk_i) begin
                if (req_i[0]) begin
                    if (we_i[0]) begin
                        for (int b = 0; b < NumBytes; b++) begin
                            if (be_i[0][b])
                                mem[addr_i[0]][b*ByteWidth +: ByteWidth] <= wdata_i[0][b*ByteWidth +: ByteWidth];
                        end
                    end
                    rdata_q <= mem[addr_i[0]];
                end
            end
            assign rdata_o[0] = rdata_q;
        end

        else if (NumPorts == 2) begin : gen_dp
            reg [DataWidth-1:0] rdata_q0, rdata_q1;

            always @(posedge clk_i) begin
                if (req_i[0]) begin
                    if (we_i[0]) begin
                        for (int b = 0; b < NumBytes; b++) begin
                            if (be_i[0][b])
                                mem[addr_i[0]][b*ByteWidth +: ByteWidth] <= wdata_i[0][b*ByteWidth +: ByteWidth];
                        end
                    end
                    rdata_q0 <= mem[addr_i[0]];
                end
            end
            assign rdata_o[0] = rdata_q0;

            always @(posedge clk_i) begin
                if (req_i[1]) begin
                    if (we_i[1]) begin
                        for (int b = 0; b < NumBytes; b++) begin
                            if (be_i[1][b])
                                mem[addr_i[1]][b*ByteWidth +: ByteWidth] <= wdata_i[1][b*ByteWidth +: ByteWidth];
                        end
                    end
                    rdata_q1 <= mem[addr_i[1]];
                end
            end
            assign rdata_o[1] = rdata_q1;
        end
    endgenerate

endmodule
