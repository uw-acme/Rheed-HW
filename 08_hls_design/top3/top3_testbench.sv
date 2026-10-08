`timescale 1ns/1ps
module top3_testbench();
    logic clk, rst_n, tvalid, tlast; // Inputs
    logic done; // Output
    logic [15:0] tdata; // Input
    logic [15:0] top_val_0, top_val_1, top_val_2; // Outputs
    logic [5:0] top_x_0, top_y_0, top_x_1, top_y_1, top_x_2, top_y_2; // Outputs

    nms_top3 dut (.clk, .rst_n, .tvalid, .tdata, .tlast, .done, .top_val_0, .top_val_1, .top_val_2, 
                    .top_x_0, .top_y_0, .top_x_1, .top_y_1, .top_x_2, .top_y_2);

    parameter CLOCK_PERIOD = 100;
    initial begin
        clk = 0;
        forever begin
            #(CLOCK_PERIOD/2) clk <= ~clk;
        end
    end

    parameter VECTOR_LENGTH = 16;
    parameter NUM_VECTORS = 1600;
    parameter NUM_KEYVALS = 9;
    logic [VECTOR_LENGTH - 1:0] mem [NUM_VECTORS - 1:0];
    logic [VECTOR_LENGTH - 1:0] key [NUM_KEYVALS - 1:0];
    initial begin
       $readmemh("top3_frame.mem", mem);
       $readmemh("top3_expected.mem", key); 
    end

    integer i = 0;

    initial begin
        rst_n <= 0; tvalid <= 0; tlast <= 0; tdata <= 0;
        repeat(3)                           @(posedge clk);
        rst_n <= 1;                         @(posedge clk);
                                            @(posedge clk);
        tvalid <= 1; tdata <= mem[0][15:0]; @(posedge clk);

        for(i = 1; i < NUM_VECTORS; i = i + 1) begin
            tdata <= mem[i][15:0];
            if(i == NUM_VECTORS - 1)
                tlast <= 1;
            @(posedge clk);
        end
        tlast <= 0; tvalid <= 0;            @(posedge clk);
        
        fork
            begin
                repeat (3000) @(posedge clk); $display ("[%0tns] TIMEOUT", $time);
                $finish;
            end

            @(posedge done);
        join_any
        disable fork;

        @(posedge clk);
        @(posedge clk);

        assert (top_val_0 == key[0])
        else   $error("Failed to match best value! Got: %0d. Expected: %0d.", top_val_0, key[0]);
        assert (top_x_0 == key[1])
        else   $error("Failed to match best x location! Got: %0d. Expected: %0d.", top_x_0, key[1]);
        assert (top_y_0 == key[2])
        else   $error("Failed to match best y location! Got: %0d. Expected: %0d.", top_y_0, key[2]);

        assert (top_val_1 == key[3])
        else   $error("Failed to match second value! Got: %0d. Expected: %0d.", top_val_1, key[3]);
        assert (top_x_1 == key[4])
        else   $error("Failed to match second x location! Got: %0d. Expected: %0d.", top_x_1, key[4]);
        assert (top_y_1 == key[5])
        else   $error("Failed to match second y location! Got: %0d. Expected: %0d.", top_y_1, key[5]);

        assert (top_val_2 == key[6])
        else   $error("Failed to match third value! Got: %0d. Expected: %0d.", top_val_2, key[6]);
        assert (top_x_2 == key[7])
        else   $error("Failed to match third x location! Got: %0d. Expected: %0d.", top_x_2, key[7]);
        assert (top_y_2 == key[8])
        else   $error("Failed to match third y location! Got: %0d. Expected: %0d.", top_y_2, key[8]);

        $display("Best value was %0d, located at x:%0d y:%0d.", top_val_0, top_x_0, top_y_0);
        $display("Second best value was %0d, located at x:%0d y:%0d.",top_val_1, top_x_1, top_y_1); 
        $display("Third best value was %0d, located at x:%0d y:%0d.", top_val_2, top_x_2, top_y_2); 

        $finish;
    end


endmodule