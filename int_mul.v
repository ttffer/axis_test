`timescale 1ns / 1ps


module int_mul #(
    parameter DATA_WIDTH=32
    
    )
   (
    input    axi_clk,
    input    axi_reset_n,
    //AXI4-S slave i/f
    input    s_axis_valid, //valid signal from master (DMA)
    input [DATA_WIDTH-1:0] s_axis_data,
    output   s_axis_ready, 
    //AXI4-S master i/f
    output  m_axis_valid, 
    output reg [DATA_WIDTH-1:0] m_axis_data,
    input    m_axis_ready, // TREADY indicates that the slave can accept a transfer in the current cycle.

    input s_axis_last,
    output m_axis_last
    );

    //local para
    // Total number of input data.
	localparam NUMBER_OF_INPUT_WORDS  = 8;
    localparam bit_num  = clogb2(NUMBER_OF_INPUT_WORDS-1);
    // FIFO write enable
	wire fifo_wren;
    // FIFO write pointer
	reg [bit_num-1:0] write_pointer;



	// I/O Connections assignments
    reg [1:0] mst_exec_state;// State variable
    parameter [1:0] IDLE = 1'b0,        // This is the initial/idle state 
	                WRITE_FIFO  = 1'b01, // In this state FIFO is written with the
	                                    // input stream data S_AXIS_TDATA 
                    EXECUTION_STATE=2'b10, //calculating fifo addition
                    SEND_STATE=2'b11;//sending msg to DMA


    wire out_reg_wren;
    wire out_reg_send_wren;
    //last signal
    wire axis_tlast;
    //valid signal
    wire axis_tvalid;
    //output reg
    reg  [(DATA_WIDTH)-1:0] stream_data_out [0 : NUMBER_OF_INPUT_WORDS-1];
    reg [bit_num-1:0]out_reg_pointer;
    reg [bit_num-1:0]out_reg_send_pointer;
    reg exe_done;
    reg send_done;
    reg writes_done;
    reg axis_tlast_delay;
    reg axis_tvalid_delay;

//I/O Connctions assignments
assign m_axis_last =axis_tlast_delay;
assign m_axis_valid =axis_tvalid_delay;


assign s_axis_ready =   ((mst_exec_state == WRITE_FIFO) && (write_pointer <= NUMBER_OF_INPUT_WORDS-1));

//write enable out reg/ reg_send
assign out_reg_wren = (mst_exec_state==EXECUTION_STATE);
//next part/output needs to be ready to receive signal
assign out_reg_send_wren =((mst_exec_state==SEND_STATE) && m_axis_ready);


//Control srate machine implementation
always@(posedge axi_clk)begin 
    if(!axi_reset_n)begin 
        mst_exec_state <= IDLE;
    end
    else begin 
        case (mst_exec_state)
        IDLE: 
	        // The sink starts accepting tdata when 
	        // there tvalid is asserted to mark the
	        // presence of valid streaming data 
	          if (s_axis_valid)
	            begin
	              mst_exec_state <= WRITE_FIFO;
	            end
	          else
	            begin
	              mst_exec_state <= IDLE;
	            end
	      WRITE_FIFO: 
	        // When the sink has accepted all the streaming input data,
	        // the interface swiches functionality to a streaming master
	        if (writes_done)
	          begin
	            mst_exec_state <= EXECUTION_STATE;
	          end
	        else
	          begin
	            // The sink accepts and stores tdata 
	            // into FIFO
	            mst_exec_state <= WRITE_FIFO;
	          end
          EXECUTION_STATE:
          begin
            if(exe_done)begin
                mst_exec_state<=SEND_STATE;
            end
            else begin
                mst_exec_state<=EXECUTION_STATE;
            end
           end
           SEND_STATE:
           begin 
            if(send_done)begin   
                mst_exec_state<=IDLE;
            end
            else begin
                mst_exec_state<=SEND_STATE;
            end
           end

	    endcase
    end

end

// AXI Streaming Sink 
	// 
	// The example design sink is always ready to accept the S_AXIS_TDATA  until
	// the FIFO is not filled with NUMBER_OF_INPUT_WORDS number of input words.
	//assign axis_tready = ((mst_exec_state == WRITE_FIFO) && (write_pointer <= NUMBER_OF_INPUT_WORDS-1));


//pointer moving
    always@(posedge axi_clk)begin 
        case (mst_exec_state)
        IDLE: 
        begin
            begin
                write_pointer <=0;
                writes_done <= 1'b0;

                out_reg_pointer<=0;
                exe_done<=1'b0;

                out_reg_send_pointer<=0;
                send_done<=1'b0;
	        end  
        end
        WRITE_FIFO:
            begin 
                    if (write_pointer <= NUMBER_OF_INPUT_WORDS-1)
                begin
                    if (fifo_wren)
                    begin
                        // write pointer is incremented after every write to the FIFO
                        // when FIFO write signal is enabled.
                        write_pointer <= write_pointer + 1;
                        writes_done <= 1'b0;
                    end
                    if ((write_pointer == NUMBER_OF_INPUT_WORDS-1)|| s_axis_last)
                        begin
                        // reads_done is asserted when NUMBER_OF_INPUT_WORDS numbers of streaming data 
                        // has been written to the FIFO which is also marked by S_AXIS_TLAST(kept for optional usage).
                        writes_done <= 1'b1;
                        end
                end  
            end
        EXECUTION_STATE:
            begin 
                    if (out_reg_pointer <= NUMBER_OF_INPUT_WORDS-1)
                begin 
                    if(out_reg_wren)
                    begin
                        out_reg_pointer<=out_reg_pointer+1;
                        exe_done<=1'b0;
                    end
                    if(out_reg_pointer==NUMBER_OF_INPUT_WORDS-1)
                    begin 
                        exe_done<=1'b1;
                    end
                end
            end
        SEND_STATE:
            begin 
                if (out_reg_send_pointer <= NUMBER_OF_INPUT_WORDS-1)
                begin 
                    if(out_reg_send_wren)
                    begin
                        out_reg_send_pointer<=out_reg_send_pointer+1;
                        send_done<=1'b0;
                    end
                    if(out_reg_send_pointer==NUMBER_OF_INPUT_WORDS-1)
                    begin 
                        send_done<=1'b1;
                    end
                end
            end

        endcase

    end
reg  [(DATA_WIDTH)-1:0] stream_data_fifo [0 : NUMBER_OF_INPUT_WORDS-1];
// FIFO write enable generation
	assign fifo_wren = s_axis_valid && s_axis_ready;
    
    

    // Streaming input data is stored in FIFO
    always @( posedge axi_clk )
    begin
    if (fifo_wren)// && S_AXIS_TSTRB[byte_index])
        begin
        stream_data_fifo[write_pointer] <= s_axis_data;
        end  
    end  
 	

//EXECUTION PHASE

    always@(posedge axi_clk)begin 
        if (out_reg_wren)begin             
            stream_data_out[out_reg_pointer]=stream_data_fifo[out_reg_pointer];            
        end
    end

//SEND PHASE
    always@(posedge axi_clk)begin 
        if (out_reg_send_wren)begin             
            m_axis_data=stream_data_out[out_reg_send_pointer];            
        end
    end
    

//valid signal
	//tvalid generation
	//axis_tvalid is asserted when the control state machine's state is SEND_STREAM and
	//number of output streaming data is less than the NUMBER_OF_OUTPUT_WORDS.
assign axis_tvalid=((mst_exec_state == SEND_STATE) && (out_reg_send_pointer <=NUMBER_OF_INPUT_WORDS-1));


//last signal
	// AXI tlast generation                                                                        
	// axis_tlast is asserted number of output streaming data is NUMBER_OF_OUTPUT_WORDS-1          
	// (0 to NUMBER_OF_OUTPUT_WORDS-1) 
assign axis_tlast = (out_reg_send_pointer==NUMBER_OF_INPUT_WORDS-1);


	// Delay the axis_tvalid and axis_tlast signal by one clock cycle                              
	// to match the latency of M_AXIS_TDATA 
always@(posedge axi_clk)begin
    if(!axi_reset_n)
    begin 
        axis_tlast_delay <= 1'b0; 
        axis_tvalid_delay<= 1'b0;
    end
    else 
    begin 
        axis_tlast_delay <= axis_tlast;
        axis_tvalid_delay<= axis_tvalid;
    end
end






/*
	always@(posedge axi_clk)
	begin
	  if(!axi_reset_n)
	    begin
	      write_pointer <= 0;
	      writes_done <= 1'b0;
	    end  
	  else
	    if (write_pointer <= NUMBER_OF_INPUT_WORDS-1)
	      begin
	        if (fifo_wren)
	          begin
	            // write pointer is incremented after every write to the FIFO
	            // when FIFO write signal is enabled.
	            write_pointer <= write_pointer + 1;
	            writes_done <= 1'b0;
	          end
	          if ((write_pointer == NUMBER_OF_INPUT_WORDS-1)|| s_axis_last)
	            begin
	              // reads_done is asserted when NUMBER_OF_INPUT_WORDS numbers of streaming data 
	              // has been written to the FIFO which is also marked by S_AXIS_TLAST(kept for optional usage).
	              writes_done <= 1'b1;
	            end
	      end  
	end
*/

/*
//inverter verilog code
    always @(posedge axi_clk)
    begin
       if(s_axis_valid & s_axis_ready)
       begin
           for(i=0;i<DATA_WIDTH/8;i=i+1)
           begin
              m_axis_data[i*8+:8] <= 255-s_axis_data[i*8+:8]; 
           end 
       end
    end
    
    always @(posedge axi_clk)
    begin
        m_axis_valid <= s_axis_valid;
    end
    */

    //FIFO implementation



    




    function integer clogb2 (input integer bit_depth);
	  begin
	    for(clogb2=0; bit_depth>0; clogb2=clogb2+1)
	      bit_depth = bit_depth >> 1;
	  end
	endfunction
endmodule
