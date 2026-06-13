module top (
    input wire clk,           // Reloj principal 27 MHz (Pin H11)
    input wire uart_rx,       // Rx de la UART (Pin T13)
    
    // Pines físicos del DAC de audio PT8121
    output wire hp_bck,
    output wire hp_ws,
    output wire hp_din,
    output wire hp_pa_en
);

    // ==========================================
    // 1. GENERADOR DE RESET AUTOMÁTICO
    // ==========================================
    reg [15:0] power_on_rst = 16'd0;
    wire rst_n = &power_on_rst; 

    always @(posedge clk) begin
        if (!rst_n) begin
            power_on_rst <= power_on_rst + 1'b1;
        end
    end

    // ==========================================
    // 2. CABLES INTERNOS DE INTERCONEXIÓN
    // ==========================================
    wire [7:0] uart_rx_data;
    wire uart_rx_ready;
    
    reg [15:0] assembler_data;
    reg assembler_valid;
    
    wire [15:0] fifo_rdata;
    wire fifo_empty;
    wire fifo_rd_en;
    
    wire [15:0] dsp_audio_wire;
    wire sync_sample_tick;

    // ==========================================
    // 3. INSTANCIA DE LA UART RX
    // ==========================================
    uart_rx u_uart (
        .clk(clk),
        .rx(uart_rx),
        .data_out(uart_rx_data),   
        .data_valid(uart_rx_ready) 
    );

// ==========================================
    // 4. ENSAMBLADOR DE BYTES (Con Auto-Sincronización)
    // ==========================================
    reg byte_state; 
    reg [7:0] byte_high;
    reg [19:0] uart_idle_cnt; // Temporizador de 10ms a 27MHz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_state <= 1'b0;
            assembler_valid <= 1'b0;
            assembler_data <= 16'd0;
            uart_idle_cnt <= 20'd0;
        end else begin
            assembler_valid <= 1'b0; 
            
            if (uart_rx_ready) begin
                uart_idle_cnt <= 20'd0; // Reiniciar temporizador al recibir datos
                
                if (byte_state == 1'b0) begin
                    byte_high <= uart_rx_data;
                    byte_state <= 1'b1;
                end else begin
                    assembler_data <= {byte_high, uart_rx_data}; 
                    assembler_valid <= 1'b1;                      
                    byte_state <= 1'b0;
                end
            end else begin
                // Si pasan aprox 10ms (270,000 ciclos) sin recibir nada de Python,
                // resincronizamos el ensamblador para evitar desalineación permanente.
                if (uart_idle_cnt < 20'd500_000) begin
                    uart_idle_cnt <= uart_idle_cnt + 1'b1;
                end else begin
                    byte_state <= 1'b0; 
                end
            end
        end
    end

    // ==========================================
    // 5. INSTANCIA DE LA FIFO (IP CORE GOWIN)
    // ==========================================
    fifo_top u_fifo (
        .Data(assembler_data), 
        .WrClk(clk), 
        .RdClk(clk), 
        .WrEn(assembler_valid), 
        .RdEn(fifo_rd_en), 
        .Q(fifo_rdata), 
        .Empty(fifo_empty), 
        .Full(), 
        .Almost_Empty(), 
        .Almost_Full()
    );

    // ==========================================
    // 6. INSTANCIA DEL DSP CORE (SINTETIZADOR)
    // ==========================================
    dsp_core u_dsp_core (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sync_sample_tick),
        .fifo_data(fifo_rdata),
        .fifo_empty(fifo_empty),
        .fifo_rd_en(fifo_rd_en),
        .dsp_out(dsp_audio_wire) // Sale el audio calculado hacia el I2S
    );

    // ==========================================
    // 7. INSTANCIA DEL TRANSMISOR I2S (DAC PT8121)
    // ==========================================
    i2s_transmitter u_i2s_tx (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(dsp_audio_wire), // Recibe el audio del DSP
        .hp_bck(hp_bck),
        .hp_ws(hp_ws),
        .hp_din(hp_din),
        .hp_pa_en(hp_pa_en),
        .sample_tick(sync_sample_tick)
    );

endmodule