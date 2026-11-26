library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.types.all;

entity bram is 
    generic (
        ADDR_W : natural := 16; 
        DATA_W : natural := 32
    ); 

    port ( 
        clk     : in std_logic; 
        -- Write port
        we      : in std_logic; 
        waddr   : in std_logic_vector(ADDR_W - 1 downto 0); 
        din     : in std_logic_vector(DATA_W - 1 downto 0); 
        -- Read port
        re      : in std_logic; 
        raddr   : in std_logic_vector(ADDR_W - 1 downto 0);
        dout    : out std_logic_vector(DATA_W - 1 downto 0) 
    );
    end entity bram;

    architecture rtl of bram is 
        type ram_t is array (0 to 2**ADDR_W - 1 ) of std_logic_vector(DATA_W-1 downto 0); 
        signal ram : ram_t := (others => (others => '0')); 

        attribute ram_style : string; 
        attribute ram_style of ram : signal is "block"; 
    begin

        process(clk) 
        begin 
            if rising_edge(clk) then 
                if we = '1' then 
                    ram(to_integer(unsigned(waddr))) <= din; -- write port
                end if; 
                
                if re = '1' then 
                    dout <= ram(to_integer(unsigned(raddr)));    -- read port
                else 
                    dout <= (others => '0'); 
                end if; 

            end if; 
        end process; 

    end architecture rtl; 
