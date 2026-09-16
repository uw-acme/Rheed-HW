`timescale 1ns/1ps
// Independent fixtures exercise the actual upstream RTL, including suppression,
// stronger-neighbor eviction, distance boundary, top-five limit and reset.
module tb_dataerai_nms;
  logic clk=0, rst_n=0, tvalid=0, tlast=0;
  logic [15:0] tdata=0;
  wire done;
  wire [15:0] v[5];
  wire [5:0] x[5], y[5];
  always #5 clk=~clk;
  nms_top5 dut(.clk(clk),.rst_n(rst_n),.tvalid(tvalid),.tdata(tdata),.tlast(tlast),.done(done),
    .top_val_0(v[0]),.top_val_1(v[1]),.top_val_2(v[2]),.top_val_3(v[3]),.top_val_4(v[4]),
    .top_x_0(x[0]),.top_x_1(x[1]),.top_x_2(x[2]),.top_x_3(x[3]),.top_x_4(x[4]),
    .top_y_0(y[0]),.top_y_1(y[1]),.top_y_2(y[2]),.top_y_3(y[3]),.top_y_4(y[4]));
  initial begin
    $dumpfile("nms-waveform.vcd"); $dumpvars(0, tb_dataerai_nms);
    repeat(2) @(negedge clk); rst_n=1;
    for (int row=0; row<40; row++) begin
      for (int col=0; col<40; col++) begin
        @(negedge clk); tvalid=1; tlast=(row==39 && col==39); tdata=0;
        if(row==2 && col==2) tdata=100;
        if(row==2 && col==3) tdata=90; // suppressed
        if(row==2 && col==4) tdata=150; // replaces weaker near slot
        if(row==2 && col==12) tdata=140; // exactly 8 apart: retained
        if(row==15 && col==2) tdata=130;
        if(row==15 && col==15) tdata=120;
        if(row==30 && col==2) tdata=110;
        if(row==30 && col==30) tdata=10; // cannot replace top five
      end
    end
    @(negedge clk); tvalid=0; tlast=0;
    if (!done) $fatal(1,"done missing");
    if(v[0]!=150 || x[0]!=4 || y[0]!=2) $fatal(1,"stronger neighbor not retained");
    if(v[1]!=140 || x[1]!=12 || y[1]!=2) $fatal(1,"distance boundary failed");
    if(v[2]!=130 || v[3]!=120 || v[4]!=110) $fatal(1,"top-five order failed");
    for(int i=0;i<5;i++) $display("PEAK %0d %0d %0d %0d",i,v[i],x[i],y[i]);
    repeat(3) @(negedge clk);
    if(!done || v[0]!=150) $fatal(1,"outputs changed while idle");
    rst_n=0; @(negedge clk);
    if(done || v[0]!=0) $fatal(1,"reset failed");
    $display("PASS: NMS suppression, eviction, distance, top-five, idle, reset");
    $finish;
  end
  initial begin #100000; $fatal(1,"simulation timeout"); end
endmodule
