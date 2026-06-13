module i2s_transmitter (
    input wire clk,                  // Reloj principal de 27 MHz (Pin H11)
    input wire rst_n,                // Reset activo en bajo
    input wire signed [15:0] data_in,// Muestra de audio monoaural desde el dsp_core
    output reg hp_bck,               // Reloj de bits (Pin N15)
    output reg hp_ws,                // Word Select / LRCK (Pin P16)
    output reg hp_din,               // Datos seriales (Pin P15)
    output wire hp_pa_en,            // Habilitación del Amplificador (Pin R16)
    output reg sample_tick           // Pulso de sincronía síncrono para el dsp_core
);

    // Activar el amplificador integrado de la placa (Activo en Alto)
    assign hp_pa_en = 1'b1;

    // 1. Generador del reloj de bits (27 MHz / 18 = 1.5 MHz)
    // Conmutamos hp_bck cada 9 ciclos del reloj principal
    reg [3:0] clk_cnt;
    always @(posedge clk or negedge rst_n) begin // <-- AQUÍ ESTABA EL ERROR
        if (!rst_n) begin
            clk_cnt <= 4'd0;
            hp_bck  <= 1'b0;
        end else begin
            if (clk_cnt == 4'd8) begin
                clk_cnt <= 4'd0;
                hp_bck  <= ~hp_bck;
            end else begin
                clk_cnt <= clk_cnt + 1'b1;
            end
        end
    end

    // Detector de flanco de bajada de hp_bck para cambiar los datos seriales
    reg prev_hp_bck;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) prev_hp_bck <= 1'b0;
        else        prev_hp_bck <= hp_bck;
    end
    wire bck_falling = (hp_bck == 1'b0 && prev_hp_bck == 1'b1);

    // 2. Máquina de serialización I2S (32 bits por frame completo)
    reg [4:0] bit_cnt; // 5 bits evitan el truncamiento al evaluar 31
    reg signed [15:0] latch_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt     <= 5'd0;
            hp_ws       <= 1'b0;
            hp_din      <= 1'b0;
            latch_data  <= 16'd0;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0; // Pulso limpio de un solo ciclo de clk (27 MHz)
            
            if (bck_falling) begin
                bit_cnt <= bit_cnt + 1'b1;
                
                // Formato I2S Estándar:
                // bit_cnt = 31 -> Fin de frame anterior, inicia canal Izquierdo (hp_ws = 0)
                if (bit_cnt == 5'd31) begin
                    hp_ws       <= 1'b0;
                    latch_data  <= data_in; // Bloqueamos la muestra matemática actual del DSP
                    sample_tick <= 1'b1;    // Se dispara el pulso para exigir el siguiente cálculo
                end 
                // bit_cnt = 15 -> Fin de canal izquierdo, inicia canal Derecho (hp_ws = 1)
                else if (bit_cnt == 5'd15) begin
                    hp_ws       <= 1'b1;
                end

                // Transmisión serial MSB-First
                // Duplicamos la señal mono en ambos canales (Izquierdo y Derecho)
                if (bit_cnt < 5'd16) begin
                    hp_din <= latch_data[5'd15 - bit_cnt]; // Canal Izquierdo (CORREGIDO a 5 bits)
                end else begin
                    hp_din <= latch_data[5'd31 - bit_cnt]; // Canal Derecho (CORREGIDO a 5 bits)
                end
            end
        end
    end

endmodule