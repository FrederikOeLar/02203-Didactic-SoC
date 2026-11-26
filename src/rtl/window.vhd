

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.types.all;

--------------------------------------------------------------
-- 3x3 word window (3 rows x 3 words = 3 x 12 pixels).
--
-- pixel_buffer(r) is a 96-bit shift register per row:
--   bits 95..64 = left word, 63..32 = centre word, 31..0 = right word
--
-- Output: pixels(3*k + m) = row k (0 top, 1 middle, 2 bottom),
--         word m (0 left, 1 centre, 2 right), with the image
--         boundaries replicated (Figure 3 in the assignment).
--------------------------------------------------------------

entity window is

    port(
        clk         : in  std_logic;
        reset       : in  std_logic;
        shift_en    : in  std_logic;    -- shift a new column into the window
        dir         : in  std_logic;    -- '0' = moving right (left shift), '1' = moving left (right shift)

        row_cnt     : in std_logic_vector(15 downto 0);
        col_cnt     : in std_logic_vector(15 downto 0);
        mem_buf_0   : in std_logic_vector(31 downto 0);
        mem_buf_1   : in std_logic_vector(31 downto 0);
        mem_input   : in std_logic_vector(31 downto 0);

        pixels      : out    word_array_t

    );

end entity window;


architecture rtl of window is

signal sel : std_logic_vector(3 downto 0);

signal pixel_buffer : pixel_matrix_t := (others => (others => '0'));

-- Replicate the centre word's first pixel into the left neighbour position
function fix_left(row : std_logic_vector(95 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(95 downto 0) := row;
begin
    r(95 downto 88) := row(39 downto 32);
    return r;
end function;

-- Replicate the centre word's last pixel into the right neighbour position
function fix_right(row : std_logic_vector(95 downto 0)) return std_logic_vector is
    variable r : std_logic_vector(95 downto 0) := row;
begin
    r(7 downto 0) := row(63 downto 56);
    return r;
end function;

begin

    --------------------------------------------------------------
    -- Shift register: new column enters on the side we move to
    --------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                pixel_buffer <= (others => (others => '0'));
            elsif shift_en = '1' then
                if dir = '0' then -- left shifting (moving right, even rows)
                    pixel_buffer(0) <= pixel_buffer(0)(63 downto 0) & mem_buf_1;
                    pixel_buffer(1) <= pixel_buffer(1)(63 downto 0) & mem_buf_0;
                    pixel_buffer(2) <= pixel_buffer(2)(63 downto 0) & mem_input;
                else              -- right shifting (moving left, odd rows)
                    pixel_buffer(0) <= mem_buf_0 & pixel_buffer(0)(95 downto 32);
                    pixel_buffer(1) <= mem_buf_1 & pixel_buffer(1)(95 downto 32);
                    pixel_buffer(2) <= mem_input & pixel_buffer(2)(95 downto 32);
                end if;
            end if;
        end if;
    end process;

    --------------------------------------------------------------
    -- Case statement to handle edge cases (combinational)
    --------------------------------------------------------------
    process(all)
        variable top, mid, bot : std_logic_vector(95 downto 0);
    begin
        top := pixel_buffer(1);
        mid := pixel_buffer(0);
        bot := pixel_buffer(2);

        case sel is
            when "0000" => -- inside the image
                null;

            when "1010" => -- upper left corner (pixel 0,0)
                top := fix_left(mid);
                mid := fix_left(mid);
                bot := fix_left(bot);

            when "0110" => -- upper right corner (pixel 0,351)
                top := fix_right(mid);
                mid := fix_right(mid);
                bot := fix_right(bot);

            when "1001" => -- lower left corner (pixel 287,0)
                top := fix_left(top);
                mid := fix_left(mid);
                bot := fix_left(mid);

            when "0101" => -- lower right corner (pixel 287,351)
                top := fix_right(top);
                mid := fix_right(mid);
                bot := fix_right(mid);

            when "0010" => -- upper edge (pixel 0,x)
                top := mid;

            when "0001" => -- lower edge (pixel 287,x)
                bot := mid;

            when "1000" => -- left edge (pixel x,0)
                top := fix_left(top);
                mid := fix_left(mid);
                bot := fix_left(bot);

            when "0100" => -- right edge (pixel x,351)
                top := fix_right(top);
                mid := fix_right(mid);
                bot := fix_right(bot);

            when others => null;
        end case;

        pixels(0) <= top(95 downto 64);
        pixels(1) <= top(63 downto 32);
        pixels(2) <= top(31 downto 0);
        pixels(3) <= mid(95 downto 64);
        pixels(4) <= mid(63 downto 32);
        pixels(5) <= mid(31 downto 0);
        pixels(6) <= bot(95 downto 64);
        pixels(7) <= bot(63 downto 32);
        pixels(8) <= bot(31 downto 0);
    end process;

     -- calculates sel signal: sel(3) => col = 0, sel(2) => col = 87 (last word), sel(1) => row = 0, sel(0) => row = 287.
    sel(3) <= '1' when unsigned(col_cnt) = 0        else '0';
    sel(2) <= '1' when unsigned(col_cnt) = 16#57#   else '0'; -- 87 = last word column (col_cnt counts words, not pixels)
    sel(1) <= '1' when unsigned(row_cnt) = 0        else '0';
    sel(0) <= '1' when unsigned(row_cnt) = 16#62A8# else '0'; -- 287 * 88 (row_cnt is already multiplied by 88)

end architecture rtl;
