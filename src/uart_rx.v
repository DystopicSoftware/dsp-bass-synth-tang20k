module uart_rx #(
    parameter CLK_FREQ = 27_000_000,
    parameter BAUD_RATE = 115_200
)(
    input clk,
    input rx,
    output reg [7:0] data_out,
    output reg data_valid
);

    localparam BIT_PERIOD = CLK_FREQ / BAUD_RATE;
    
    reg [15:0] count = 0;
    reg [3:0] bit_idx = 0;
    reg [7:0] shift_reg = 0;
    reg rx_reg = 1;
    reg rx_prev = 1;

    always @(posedge clk) begin
        rx_prev <= rx_reg;
        rx_reg <= rx;
        
        data_valid <= 0;
        
        if (bit_idx == 0) begin
            if (rx_prev && !rx_reg) begin // Inicio de bit (flanco de bajada)
                bit_idx <= 1;
                count <= 0;
            end
        end else begin
            if (count < BIT_PERIOD - 1) begin
                count <= count + 16'd1;
            end else begin
                count <= 0;
                if (bit_idx <= 8) begin
                    shift_reg <= {rx_reg, shift_reg[7:1]};
                    bit_idx <= bit_idx + 4'd1;
                end else begin
                    data_out <= shift_reg;
                    data_valid <= 1;
                    bit_idx <= 0;
                end
            end
        end
    end
endmodule