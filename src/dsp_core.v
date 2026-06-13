module dsp_core (
    input wire clk,          // Reloj principal de 27 MHz
    input wire rst_n,        // Reset activo en bajo
    input wire sample_tick,  // Viene del i2s_transmitter (~48 kHz)
    
    // Interfaz con la FIFO (UART RX)
    input wire [15:0] fifo_data,
    input wire fifo_empty,
    output reg fifo_rd_en,
    
    // Salida de audio procesada hacia el DAC
    output reg signed [15:0] dsp_out
);

    localparam SLAP_SAMPLES = 4800;

    // Memorias físicas de Hardware (BSRAM)
    reg signed [15:0] delay_line [0:2047];
    reg signed [15:0] slap_buffer [0:4799];
    
    integer i;
    initial begin
        // Dividimos los 2048 de la delay_line en 2 ciclos limpios para el sintetizador
        for (i = 0; i < 1024; i = i + 1) begin
            delay_line[i] = 16'd0;
        end
        for (i = 1024; i < 2048; i = i + 1) begin
            delay_line[i] = 16'd0;
        end

        // Dividimos los 4800 del slap_buffer en 3 ciclos
        for (i = 0; i < 1600; i = i + 1) begin
            slap_buffer[i] = 16'd0;
        end
        for (i = 1600; i < 3200; i = i + 1) begin
            slap_buffer[i] = 16'd0;
        end
        for (i = 3200; i < 4800; i = i + 1) begin
            slap_buffer[i] = 16'd0;
        end
    end

    // REGISTROS DINÁMICOS DESDE PYTHON
    reg [11:0] delay_samples  = 12'd1166; 
    reg [11:0] param_wobble   = 12'd0;    
    reg [11:0] param_drive    = 12'd0;    
    reg [11:0] param_lenta    = 12'd0; 
    reg [11:0] param_volume   = 12'd1024; // <--- NUEVO: Inicia en ~25% de volumen por seguridad   
    reg        gate_global    = 1'b0;     // Captura el estado Presionado/Suelto
    

    // Punteros
    reg [10:0] wr_ptr;
    wire [10:0] rd_ptr;
    assign rd_ptr = wr_ptr - delay_samples[10:0];

    reg [12:0] preload_ptr;       
    reg [12:0] slap_playback_ptr; 

    // Salidas síncronas de las RAMs
    reg signed [15:0] string_output;
    reg signed [15:0] slap_sample_out;

    always @(posedge clk) begin
        string_output   <= delay_line[rd_ptr];
        slap_sample_out <= slap_buffer[slap_playback_ptr];
    end

    reg is_preloading;  
    reg slap_playing;   
    reg [1:0] state;

    // REGISTROS DEL LAZO DSP INTERNO (FAUST)
    reg signed [15:0] lp_out;              
    reg signed [15:0] dc_block_out;        
    reg signed [15:0] dc_block_in_prev;    

    // Variables de control LFO de Faust
    reg [15:0] lfo_phase;
    reg signed [15:0] lfo_sincronizado;

    // --- VARIABLES INTERMEDIAS DE ALTA PRECISIÓN (Previene pérdida de signo) ---
    reg signed [15:0] excitation;
    reg signed [16:0] input_to_filter; 
    reg signed [16:0] c_val_calc;
    reg signed [15:0] c_val;
    reg signed [33:0] lp_mult;         // 18 bits * 16 bits = 34 bits necesarios
    reg signed [33:0] lp_calc;
    reg signed [33:0] sat_calc;
    reg signed [15:0] sat_out;
    reg signed [16:0] g_val_calc;
    reg signed [33:0] gain_calc;
    reg signed [15:0] scaled_out;
    reg signed [33:0] dc_mult;
    reg signed [33:0] dc_calc;
    reg signed [33:0] vol_calc; // <--- NUEVO: Variable para calcular el volumen sin overflow


// Registro para no perder NUNCA el tick del i2s aunque estemos leyendo UART
    reg tick_latched;
    reg signed [15:0] current_lp_out; // Almacén intermedio sin retraso

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            is_preloading     <= 1'b1; 
            preload_ptr       <= 13'd0;
            slap_playing      <= 1'b0;
            slap_playback_ptr <= 13'd0;
            wr_ptr            <= 11'd0;
            fifo_rd_en        <= 1'b0;
            dsp_out           <= 16'd0;
            state             <= 2'd0;
            lp_out            <= 16'd0;
            dc_block_out      <= 16'd0;
            dc_block_in_prev  <= 16'd0;
            lfo_phase         <= 16'd0;
            lfo_sincronizado  <= 16'sd0;
            gate_global       <= 1'b0;
            delay_samples     <= 12'd1166;
            param_lenta       <= 12'd0;
            param_wobble      <= 12'd0;
            param_drive       <= 12'd0;
            param_volume      <= 12'd1024; // <--- Añadir esta línea
            tick_latched      <= 1'b0;
        end else begin
            
            // Atrapamos el pulso de audio de 1 ciclo pase lo que pase
            if (sample_tick) tick_latched <= 1'b1;

            if (is_preloading) begin
                if (!fifo_empty && !fifo_rd_en) begin
                    fifo_rd_en <= 1'b1; 
                end else if (fifo_rd_en) begin
                    fifo_rd_en <= 1'b0; 
                    slap_buffer[preload_ptr] <= fifo_data; 
                    if (preload_ptr == (SLAP_SAMPLES - 1)) is_preloading <= 1'b0; 
                    else preload_ptr <= preload_ptr + 1'b1;
                end
            end 
            else begin
                case (state)
                    2'd0: begin // IDLE CON PRIORIDAD ESTRICTA
                        fifo_rd_en <= 1'b0;
                        if (tick_latched) begin
                            state        <= 2'd2; // El audio tiene prioridad absoluta
                            tick_latched <= 1'b0; // Limpiamos el latch
                        end else if (!fifo_empty) begin
                            fifo_rd_en   <= 1'b1;        
                            state        <= 2'd1; 
                        end
                    end
                    
                    2'd1: begin // DECODER DE PROTOCOLO DE 16 BITS
                    fifo_rd_en <= 1'b0;
                    case (fifo_data[15:12])
                        4'd0: delay_samples <= fifo_data[11:0];
                        4'd1: param_lenta   <= fifo_data[11:0];
                        4'd2: param_wobble  <= fifo_data[11:0];
                        4'd3: param_drive   <= fifo_data[11:0];
                        4'd4: begin 
                            gate_global <= fifo_data[0];
                            if (fifo_data[0]) begin
                                slap_playing      <= 1'b1; 
                                slap_playback_ptr <= 13'd0;
                            end
                        end
                        4'd5: param_volume <= fifo_data[11:0]; // <--- NUEVO COMANDO ACEPTADO
                    endcase
                    state <= 2'd0;
                end
                    
                    2'd2: begin // NÚCLEO MATEMÁTICO BLINDADO
                        
                        // --- 0. Entrada y Suma Segura a 17 Bits (Cero Overflow) ---
                        excitation = (slap_playing) ? slap_sample_out : 16'sd0;
                        // Extendemos el bit de signo explícitamente a 17 bits ANTES de la suma
                        input_to_filter = $signed({{1{string_output[15]}}, string_output}) + $signed({{1{excitation[15]}}, excitation});
                        
                        // --- 1. LFO ---
                        if (gate_global) begin
                            lfo_phase        <= 16'd0;
                            lfo_sincronizado <= 16'sd0;
                        end else begin
                            lfo_phase <= lfo_phase + 16'd4; 
                            lfo_sincronizado <= (lfo_phase[15] ? -16'sd4000 : 16'sd4000); 
                        end
                        
                        // --- 2. Filtro Dinámico ---
                        c_val_calc = 17'sd9830 - $signed({5'd0, param_lenta});
                        if (!gate_global) begin
                            c_val_calc = c_val_calc + ((lfo_sincronizado * $signed({5'd0, param_wobble})) >>> 12);
                        end
                        if (c_val_calc < 17'sd327)       c_val = 16'sd327;
                        else if (c_val_calc > 17'sd32440) c_val = 16'sd32440;
                        else                              c_val = c_val_calc[15:0];
                        
                        // --- 3. Filtro Lowpass (CON REDONDEO ANTI-RUIDO BLANCO) ---
                        lp_mult = ($signed(input_to_filter) - $signed({{2{lp_out[15]}}, lp_out})) * $signed(c_val);
                        // ¡MAGIA! Sumamos 16384 antes de hacer >>> 15 para redondear matemáticamente
                        lp_calc = $signed(lp_out) + ((lp_mult + 34'sd16384) >>> 15);
                        
                        if (lp_calc > 33'sd32767)       current_lp_out = 16'sd32767;
                        else if (lp_calc < -33'sd32768) current_lp_out = -16'sd32768;
                        else                            current_lp_out = lp_calc[15:0];
                        
                        lp_out <= current_lp_out; 
                        
                        // --- 4. Saturador ---
                        if (param_drive > 12'd0) begin
                            sat_calc = ($signed(current_lp_out) * ($signed({5'd0, param_drive}) + 17'sd16384)) >>> 14;
                            if (sat_calc > 33'sd24000)       sat_out = 16'sd24000;
                            else if (sat_calc < -33'sd24000) sat_out = -16'sd24000;
                            else                             sat_out = sat_calc[15:0];
                        end else begin
                            sat_out = current_lp_out;
                        end

                        // --- 5. Compensación (CON REDONDEO) ---
                        g_val_calc = 17'sd32276 + ($signed({5'd0, param_lenta}) >>> 3) - ($signed({5'd0, param_drive}) >>> 1);
                        if (g_val_calc > 17'sd32500)      g_val_calc = 17'sd32500;
                        else if (g_val_calc < 17'sd16000) g_val_calc = 17'sd16000; 

                        // Sumamos 16384 al multiplicador antes de truncar
                        gain_calc = ((sat_out * $signed(g_val_calc)) + 34'sd16384) >>> 15;
                        
                        if (gain_calc > 33'sd32767)       scaled_out = 16'sd32767;
                        else if (gain_calc < -33'sd32768) scaled_out = -16'sd32768;
                        else                              scaled_out = gain_calc[15:0];
                        
                        // --- 6. Filtro DC Blocker (CON REDONDEO ANTI-RUIDO BLANCO) ---
                        dc_mult = 17'sd32604 * $signed(dc_block_out); 
                        // Sumamos 16384 para redondear y que el DC Blocker muera en 0 absoluto, no en "ruido"
                        dc_calc = ($signed({{2{scaled_out[15]}}, scaled_out}) - $signed({{2{dc_block_in_prev[15]}}, dc_block_in_prev})) + ((dc_mult + 34'sd16384) >>> 15);
                        
                        if (dc_calc > 33'sd32767)       dc_block_out <= 16'sd32767;
                        else if (dc_calc < -33'sd32768) dc_block_out <= -16'sd32768;
                        else                            dc_block_out <= dc_calc[15:0];
                        
                        dc_block_in_prev <= scaled_out;
                        
                    // --- 7. Feedback e Inyección ---
                    delay_line[wr_ptr] <= dc_block_out;
                    
                    // --- 8. MASTER VOLUME (Atenuador Q12 Seguro) ---
                    // Multiplicamos la salida cruda por el volumen (0 a 4095). 
                    // Desplazar 12 bits normaliza la señal (4095/4096 = 0.999), 
                    // garantizando que NUNCA habrá overflow en la salida final.
                    vol_calc = ($signed(string_output) * $signed({5'd0, param_volume})) >>> 12;
                    dsp_out  <= vol_calc[15:0]; 
                    
                    wr_ptr   <= wr_ptr + 1'b1;
                        
                        if (slap_playing) begin
                            if (slap_playback_ptr == (SLAP_SAMPLES - 1)) begin
                                slap_playing      <= 1'b0;
                                slap_playback_ptr <= 13'd0;
                            end else begin
                                if (param_lenta == 12'd0 || wr_ptr[0] == 1'b1) begin
                                    slap_playback_ptr <= slap_playback_ptr + 1'b1;
                                end
                            end
                        end
                        state <= 2'd0;
                    end
                    default: state <= 2'd0;
                endcase
            end
        end
    end
endmodule // <--- 
