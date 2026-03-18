`timescale 1ns / 1ps

module tb_img_process();

// =========================================================================
// 1. 参数定义 (必须与 Python 脚本生成的尺寸绝对一致！)
// =========================================================================
parameter IMG_WIDTH  = 200;
parameter IMG_HEIGHT = 100;
parameter PIXEL_NUM  = IMG_WIDTH * IMG_HEIGHT;

// 仿真帧数控制：至少 3 帧才能完整验证 "投影计算→OSD 画框" 流程
//   帧 1：projection_extractor 累加投影、计算坐标
//   帧 2：osd_draw_box 用帧 1 的坐标画框 ← 捕获此帧
//   帧 3：进入后仿真停止
parameter SIM_FRAMES = 3;

// 模拟视频时序参数 (缩小消隐区以加快仿真)
parameter H_SYNC  = 10;
parameter H_BACK  = 10;
parameter H_DISP  = IMG_WIDTH;
parameter H_FRONT = 10;
parameter H_TOTAL = H_SYNC + H_BACK + H_DISP + H_FRONT;

parameter V_SYNC  = 2;
parameter V_BACK  = 30;
parameter V_DISP  = IMG_HEIGHT;
parameter V_FRONT = 2;
parameter V_TOTAL = V_SYNC + V_BACK + V_DISP + V_FRONT;

// =========================================================================
// 2. 信号定义
// =========================================================================
reg         clk;
reg         rst_n;

reg         cam_vsync;
reg         cam_hsync;
reg         cam_de;
reg  [23:0] cam_data;

wire        out_vsync;
wire        out_de;
wire [7:0]  out_data;

wire        out_osd_vs;
wire        out_osd_de;
wire [23:0] out_osd_rgb;

reg [11:0]  h_cnt;
reg [11:0]  v_cnt;
reg [31:0]  pixel_cnt;

reg [23:0]  img_mem [0:PIXEL_NUM-1];

integer     file_out;

// =========================================================================
// 3. 时钟与复位
// =========================================================================
initial begin
    clk = 0;
    forever #10 clk = ~clk;
end

initial begin
    rst_n = 0;
    #100;
    rst_n = 1;
end

// =========================================================================
// 4. 读取激励数据
// =========================================================================
initial begin
    $readmemh("D:/fpga_pj/image3.txt", img_mem);

    file_out = $fopen("D:/fpga_pj/image_out.txt", "w");
    if (!file_out) begin
        $display("[!] ERROR: Cannot create image_out.txt");
        $stop;
    end
end

// =========================================================================
// 5. 虚拟视频时序发生器
// =========================================================================
// 组合逻辑 DE，用于像素数据同步加载（消除 cam_de 与 cam_data 的 1 拍错位）
wire de_comb = ((h_cnt >= H_SYNC + H_BACK) && (h_cnt < H_SYNC + H_BACK + H_DISP) &&
                (v_cnt >= V_SYNC + V_BACK) && (v_cnt < V_SYNC + V_BACK + V_DISP));

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_cnt     <= 0;
        v_cnt     <= 0;
        cam_vsync <= 0;
        cam_hsync <= 0;
        cam_de    <= 0;
        cam_data  <= 24'd0;
        pixel_cnt <= 0;
    end else begin
        if (h_cnt == H_TOTAL - 1) begin
            h_cnt <= 0;
            if (v_cnt == V_TOTAL - 1)
                v_cnt <= 0;
            else
                v_cnt <= v_cnt + 1;
        end else begin
            h_cnt <= h_cnt + 1;
        end

        cam_hsync <= (h_cnt < H_SYNC) ? 1'b1 : 1'b0;
        cam_vsync <= (v_cnt < V_SYNC) ? 1'b1 : 1'b0;

        // cam_de 和 cam_data 都基于 de_comb 驱动，保证同拍对齐送入 DUT
        cam_de <= de_comb;

        if (de_comb) begin
            cam_data  <= img_mem[pixel_cnt];
            if (pixel_cnt == PIXEL_NUM - 1)
                pixel_cnt <= 0;
            else
                pixel_cnt <= pixel_cnt + 1;
        end else begin
            cam_data <= 24'd0;
        end
    end
end

// =========================================================================
// 6. 实例化 DUT
// =========================================================================
image_process_wrapper #(
    .IMG_WIDTH  ( IMG_WIDTH  ),
    .IMG_HEIGHT ( IMG_HEIGHT )
) u_image_process_wrapper (
    .clk        ( clk ),
    .rst_n      ( rst_n ),

    .vs_in      ( cam_vsync ),
    .de_in      ( cam_de ),
    .r_in       ( cam_data[23:16] ),
    .g_in       ( cam_data[15:8]  ),
    .b_in       ( cam_data[7:0]   ),

    .post_vs   ( out_vsync ),
    .post_de   ( out_de ),
    .post_data ( out_data ),

    .osd_vs    ( out_osd_vs ),
    .osd_de    ( out_osd_de ),
    .osd_rgb   ( out_osd_rgb )
);

// =========================================================================
// 7. 二值化输出捕获（仅写入最后一个完整处理帧）
// =========================================================================
reg [11:0] frame_cnt = 0;
always @(negedge out_vsync) begin
    if (!rst_n)
        frame_cnt <= 0;
    else
        frame_cnt <= frame_cnt + 1;
end

always @(posedge clk) begin
    if (out_de && frame_cnt == SIM_FRAMES - 1) begin
        $fwrite(file_out, "%02x\n", out_data);
    end
end

// =========================================================================
// 8. OSD 全彩输出捕获（捕获带有效画框的帧）
// =========================================================================
integer rgb_file;
initial begin
    rgb_file = $fopen("D:/fpga_pj/image_out_rgb.txt", "w");
    if (!rgb_file) begin
        $display("[!] ERROR: Cannot create image_out_rgb.txt");
        $stop;
    end
end

reg [3:0] osd_frame_cnt = 0;
always @(posedge out_osd_vs) begin
    osd_frame_cnt <= osd_frame_cnt + 1;
end

always @(posedge clk) begin
    if (out_osd_de && osd_frame_cnt == SIM_FRAMES - 1) begin
        $fwrite(rgb_file, "%02x%02x%02x\n",
                out_osd_rgb[23:16], out_osd_rgb[15:8], out_osd_rgb[7:0]);
    end
end

// =========================================================================
// 9. 帧进度显示与仿真结束控制
// =========================================================================
always @(posedge frame_cnt[0] or posedge frame_cnt[1] or
         posedge frame_cnt[2] or posedge frame_cnt[3]) begin
    $display("[*] Frame %0d / %0d completed (sim time = %0t)",
             frame_cnt, SIM_FRAMES, $time);
end

always @(negedge out_vsync) begin
    if (frame_cnt == SIM_FRAMES - 1) begin
        $display("[+] Simulation finished: %0d frames processed.", SIM_FRAMES);
        $fclose(file_out);
        $fclose(rgb_file);
        #100;
        $stop;
    end
end

endmodule
