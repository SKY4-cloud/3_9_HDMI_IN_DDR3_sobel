`timescale 1ns / 1ps

module image_process_wrapper #(
    parameter IMG_WIDTH  = 200, // 仿真时会被 Testbench 覆盖
    parameter IMG_HEIGHT = 100
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // 从虚拟摄像头输入的信号
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [7:0]  r_in,
    input  wire [7:0]  g_in,
    input  wire [7:0]  b_in,
    
    // 算法处理完输出的信号
    output wire        sobel_vs,
    output wire        sobel_de,
    output wire [7:0]  sobel_data
);

// 内部连接线 [cite: 117, 121, 129]
wire        y_vs;
wire        y_hs;
wire        y_de;
wire [7:0]  y_data;

wire        matrix_de;
wire [7:0]  matrix11, matrix12, matrix13;
wire [7:0]  matrix21, matrix22, matrix23;
wire [7:0]  matrix31, matrix32, matrix33;

// 1. 灰度化模块实例化 (完全参照官方连线) [cite: 118, 119]
RGB2YCbCr RGB2YCbCr_inst (
    .clk        (clk),              
    .rst_n      (rst_n),          
    .vsync_in   (vs_in),    
    .hsync_in   (de_in),  // 官方代码这里将 de 接给了 hsync   
    .de_in      (de_in),          
    .red        (r_in[7:3]),  // 取高位，RGB888 转 RGB565             
    .green      (g_in[7:2]),          
    .blue       (b_in[7:3]),            
    .vsync_out  (y_vs),  
    .hsync_out  (y_hs),  
    .de_out     (y_de),        
    .y          (y_data),                  
    .cb         (),              
    .cr         ()                 
);

// 2. 3x3 矩阵生成模块实例化 [cite: 126, 127]
matrix_3x3 #(
    .IMG_WIDTH  ( IMG_WIDTH  ), // 使用传入的参数！
    .IMG_HEIGHT ( IMG_HEIGHT )
) u_matrix_3x3 (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .video_vs   ( y_vs ),
    .video_de   ( y_de ),
    .video_data ( y_data ),
    .matrix_de  ( matrix_de ),
    .matrix11   ( matrix11 ), .matrix12   ( matrix12 ), .matrix13   ( matrix13 ),
    .matrix21   ( matrix21 ), .matrix22   ( matrix22 ), .matrix23   ( matrix23 ),
    .matrix31   ( matrix31 ), .matrix32   ( matrix32 ), .matrix33   ( matrix33 )
);

// 3. Sobel 边缘检测模块实例化 [cite: 132, 133]
sobel #(
    .SOBEL_THRESHOLD ( 64 ) // 保持与官方顶层一致的 64 阈值 
) u_sobel (
    .video_clk  ( clk ),
    .rst_n      ( rst_n ),
    .matrix_de  ( matrix_de ),
    .matrix_vs  ( y_vs ),
    .matrix11   ( matrix11 ), .matrix12   ( matrix12 ), .matrix13   ( matrix13 ),
    .matrix21   ( matrix21 ), .matrix22   ( matrix22 ), .matrix23   ( matrix23 ),
    .matrix31   ( matrix31 ), .matrix32   ( matrix32 ), .matrix33   ( matrix33 ),
    .sobel_vs   ( sobel_vs ),
    .sobel_de   ( sobel_de ),
    .sobel_data ( sobel_data )
);

endmodule