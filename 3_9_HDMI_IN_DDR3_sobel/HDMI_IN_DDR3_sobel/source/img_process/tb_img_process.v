`timescale 1ns / 1ps

module tb_img_process();

// =========================================================================
// 1. 参数定义 (必须与 Python 脚本生成的尺寸绝对一致！)
// =========================================================================
parameter IMG_WIDTH  = 200;    // 图像宽度
parameter IMG_HEIGHT = 100;    // 图像高度
parameter PIXEL_NUM  = IMG_WIDTH * IMG_HEIGHT; // 总像素数

// 模拟视频时序参数 (为了加快仿真速度，这里的消隐区设置得很小)
parameter H_SYNC  = 10;
parameter H_BACK  = 10;
parameter H_DISP  = IMG_WIDTH;
parameter H_FRONT = 10;
parameter H_TOTAL = H_SYNC + H_BACK + H_DISP + H_FRONT;

parameter V_SYNC  = 2;
parameter V_BACK  = 2;
parameter V_DISP  = IMG_HEIGHT;
parameter V_FRONT = 2;
parameter V_TOTAL = V_SYNC + V_BACK + V_DISP + V_FRONT;

// =========================================================================
// 2. 信号定义
// =========================================================================
reg         clk;            // 模拟系统时序 (如 50MHz)
reg         rst_n;          // 低电平复位

// 虚拟摄像头输出给 DUT(待测模块) 的信号
reg         cam_vsync;
reg         cam_hsync;
reg         cam_de;         // 数据有效使能 (Data Enable)
reg  [23:0] cam_data;       // 24bit RGB 像素数据

// DUT 输出的信号 (准备抓取用来验证)
wire        out_vsync;
wire        out_hsync;
wire        out_de;
wire [7:0]  out_data;       // 假设 Sobel 出来是 8bit 灰度/二值化数据

// 内部控制变量
reg [11:0]  h_cnt;          // 行计数器
reg [11:0]  v_cnt;          // 场计数器
reg [31:0]  pixel_cnt;      // 已读取的像素计数

// 内存数组，用来一口吞下整个 TXT 文件
reg [23:0]  img_mem [0:PIXEL_NUM-1]; 

integer     file_out;       // 输出文件句柄

// =========================================================================
// 3. 时钟与复位生成 (系统的“心脏”)
// =========================================================================
initial begin
    clk = 0;
    forever #10 clk = ~clk; // 产生 50MHz 时钟 (周期20ns)
end

initial begin
    rst_n = 0;
    #100;
    rst_n = 1;              // 100ns 后释放复位
end

// =========================================================================
// 4. 读取 Python 生成的激励数据 (注入“灵魂”)
// =========================================================================
initial begin
    // 【老兵排雷】: 确保 "image_in.txt" 放在 Modelsim 仿真目录 (通常是工作区的根目录)
    $readmemh("D:/fpga_pj/image1.txt", img_mem);
    
    // 打开一个文件用来保存输出结果
    file_out = $fopen("D:/fpga_pj/image_out.txt", "w");
    if (!file_out) begin
        $display("[!] 错误: 无法创建输出文件 image_out.txt");
        $stop;
    end
end

// =========================================================================
// 5. 虚拟视频时序发生器 (模拟真实 HDMI/摄像头 的 HSYNC, VSYNC, DE)
// =========================================================================
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
        // 行计数器
        if (h_cnt == H_TOTAL - 1) begin
            h_cnt <= 0;
            // 场计数器
            if (v_cnt == V_TOTAL - 1)
                v_cnt <= 0;
            else
                v_cnt <= v_cnt + 1;
        end else begin
            h_cnt <= h_cnt + 1;
        end

        // 产生同步信号 (高有效或低有效取决于你的具体模块，这里用高有效举例)
        cam_hsync <= (h_cnt < H_SYNC) ? 1'b1 : 1'b0;
        cam_vsync <= (v_cnt < V_SYNC) ? 1'b1 : 1'b0;

        // 产生数据有效信号 DE (Data Enable)
        cam_de <= ((h_cnt >= H_SYNC + H_BACK) && (h_cnt < H_SYNC + H_BACK + H_DISP) &&
                   (v_cnt >= V_SYNC + V_BACK) && (v_cnt < V_SYNC + V_BACK + V_DISP)) ? 1'b1 : 1'b0;

        // 当 DE 有效时，从内存中吐出一个像素
        if (cam_de) begin
            cam_data  <= img_mem[pixel_cnt];
            if (pixel_cnt == PIXEL_NUM - 1)
                pixel_cnt <= 0; // 一帧结束，循环读取
            else
                pixel_cnt <= pixel_cnt + 1;
        end else begin
            cam_data <= 24'd0;  // 消隐区数据置零
        end
    end
end

// =========================================================================
// 6. 实例化待测模块 (DUT) - 接入剥离出的纯净流水线
// =========================================================================
image_process_wrapper #(
    .IMG_WIDTH  ( IMG_WIDTH  ), // 200
    .IMG_HEIGHT ( IMG_HEIGHT )  // 100
) u_image_process_wrapper (
    .clk        ( clk ),
    .rst_n      ( rst_n ),
    
    // 输入：Testbench 虚拟摄像头的数据
    .vs_in      ( cam_vsync ),
    .de_in      ( cam_de ),
    .r_in       ( cam_data[23:16] ), // 提取 24bit 里的 Red 通道
    .g_in       ( cam_data[15:8]  ), // 提取 Green 通道
    .b_in       ( cam_data[7:0]   ), // 提取 Blue 通道
    
    // 输出：抓取 Sobel 的结果写入 TXT
    .post_vs   ( out_vsync ),
    .post_de   ( out_de ),
    .post_data ( out_data )
);

// =========================================================================
// 7. 捕获输出并写入文件 (准备交回给 Python)
// =========================================================================
// 当 DUT 输出 DE 为高时，将处理结果写回 TXT 文件
always @(posedge clk) begin
    if (out_de) begin
        // 将 8bit 数据以十六进制格式写入文件，并换行
        $fwrite(file_out, "%02x\n", out_data);
    end
end

// 控制仿真结束条件：当第一帧数据完全写入后，停止仿真
reg  [11:0] frame_cnt;
always @(negedge out_vsync) begin // 场同步下降沿代表一帧结束
    if (!rst_n) 
        frame_cnt <= 0;
    else begin
        frame_cnt <= frame_cnt + 1;
        if (frame_cnt == 1) begin // 跑完完整的一帧就停
            $display("[+] 仿真结束：一帧图像已处理完毕！");
            $fclose(file_out);    // 必须关闭文件，否则数据写不进去！
            #10000;$stop;                // 暂停仿真
        end
    end
end

endmodule