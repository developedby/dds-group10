library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use IEEE.math_real.all;

-- Modular exponentiation using iterated right-to-left application of the montgomery product.
-- High-level algorithm:
-- def mon_exp_rl(msg, e, n):
--     r2_mod = (1 << (2*k)) % n
--     product = mon_pro(msg, r2_mod, n)
--     result = mon_pro(1, r2_mod, n)
--     for i in range(k):
--         if get_bit(e, i):
--             result = mon_pro(result, product, n)
--         product = mon_pro(product, product, n)
--     result = mon_pro(result, 1, n)
--     return result
entity MonExpr is
  generic (k : positive := 256);
  port (
    clk    : in  std_logic;
    rst_n  : in  std_logic;
    load   : in  std_logic;
    msg    : in  unsigned(k - 1 downto 0);
    e      : in  unsigned(k - 1 downto 0);
    n      : in  unsigned(k - 1 downto 0);
    r2     : in  unsigned(k - 1 downto 0); -- Precalculated 2^(2*k) mod n (shifting factor to montgomery space)
    done   : out std_logic;
    result : out unsigned(k - 1 downto 0)
  );
end entity MonExpr;

architecture rtl of MonExpr is
  -- Registers / state
  signal r2_reg      : unsigned(k - 1 downto 0);
  signal e_reg       : unsigned(k - 1 downto 0);
  signal n_reg       : unsigned(k - 1 downto 0);
  signal product_reg : unsigned(k - 1 downto 0);
  signal result_reg  : unsigned(k - 1 downto 0);
  signal done_reg    : std_logic;

  -- Main FSM
  -- Idle       : Sit at idle until load is signaled, store the inputs.
  -- To Mongom  : Transform the product and result variables into the Montgomery space by left shifting (with modulo)
  -- Loop       : Iterated squaring of the message and accumulating it in the result.
  -- From Mongom: Bring the result back from the Montgomery space into normal number space.
  type state_t is (idle_s, to_mongom_s, loop_s, from_mongom_s);
  signal crnt_state : state_t;

  -- Next state signals
  signal next_state       : state_t;
  signal next_r2_reg      : unsigned(k - 1 downto 0);
  signal next_product_reg : unsigned(k - 1 downto 0);
  signal next_e_reg       : unsigned(k - 1 downto 0);
  signal next_n_reg       : unsigned(k - 1 downto 0);
  signal next_result_reg  : unsigned(k - 1 downto 0);
  signal next_done_reg    : std_logic;

  -- Loop counter signals
  signal counter_reg : unsigned(positive(log2(real(k))) - 1 downto 0);
  signal count_done  : std_logic;
  signal count_en    : std_logic;

  -- Montgomery Product module, calculates P = A*B*2^-k mod N
  component MonPro is
    generic (k : positive := 256);
    port (
      clk   : in  std_logic;
      rst_n : in  std_logic;
      load  : in  std_logic;
      A     : in  unsigned(k - 1 downto 0);
      B     : in  unsigned(k - 1 downto 0);
      N     : in  unsigned(k - 1 downto 0);
      done  : out std_logic;
      P     : out unsigned(k - 1 downto 0));
  end component MonPro;

  -- To control when to load the MonPro, active when it's the first cycle of a state.
  signal first_cycle : std_logic;

  -- MonPro signals
  signal monpro_n : unsigned(k - 1 downto 0);
  -- I'm expecting both to be done at the same time and only reading one of them at a time.
  -- TODO: think about this
  signal p_monpro_done : std_logic;
  signal p_monpro_load : std_logic;
  signal p_monpro_a    : unsigned(k - 1 downto 0);
  signal p_monpro_b    : unsigned(k - 1 downto 0);
  signal p_monpro_p    : unsigned(k - 1 downto 0);
  signal r_monpro_done : std_logic;
  signal r_monpro_load : std_logic;
  signal r_monpro_a    : unsigned(k - 1 downto 0);
  signal r_monpro_b    : unsigned(k - 1 downto 0);
  signal r_monpro_p    : unsigned(k - 1 downto 0);

begin

  -- Update the registers at every clock with calculated next value
  regs : process (rst_n, clk)
  begin
    if rst_n = '0' then
      first_cycle <= '0';
      crnt_state  <= idle_s;
      r2_reg      <= (others => '0');
      e_reg       <= (others => '0');
      n_reg       <= (others => '0');
      product_reg <= (others => '0');
      result_reg  <= (others => '0');
      done_reg    <= '0';
    elsif rising_edge(clk) then
      first_cycle <= '1' when next_state /= crnt_state else
                     '0';
      crnt_state  <= next_state;
      r2_reg      <= next_r2_reg;
      e_reg       <= next_e_reg;
      n_reg       <= next_n_reg;
      product_reg <= next_product_reg;
      result_reg  <= next_result_reg;
      done_reg    <= next_done_reg;
    end if;
  end process;

  -- Calculates next state values and control for the sub-components
  comb : process (all)
  begin
    -- Always
    result   <= result_reg;
    monpro_n <= n_reg;

    -- Default values
    next_state       <= crnt_state;
    next_r2_reg      <= r2_reg;
    next_e_reg       <= e_reg;
    next_n_reg       <= n_reg;
    next_product_reg <= product_reg;
    next_result_reg  <= result_reg;
    next_done_reg    <= done_reg;
    count_en         <= '0';
    done             <= '0';
    r_monpro_a       <= (others => '0');
    r_monpro_b       <= (others => '0');
    r_monpro_load    <= '0';
    p_monpro_a       <= (others => '0');
    p_monpro_b       <= (others => '0');
    p_monpro_load    <= '0';

    case crnt_state is
      when idle_s =>
        if load = '1' then
          next_state       <= to_mongom_s;
          next_r2_reg      <= r2;
          next_e_reg       <= e;
          next_n_reg       <= n;
          next_product_reg <= msg;
          next_result_reg  <= (0 => '1', others => '0');
          next_done_reg    <= '0';
        end if;
      when to_mongom_s =>
        -- Product and result variables into Montgomery space (left shift k bits (mod n))
        -- product = mon_pro(msg, r2_mod, n)
        -- result  = mon_pro(1, r2_mod, n)
        if first_cycle = '1' then
          p_monpro_load <= '1';
          p_monpro_a    <= product_reg;
          p_monpro_b    <= r2_reg;
          r_monpro_load <= '1';
          r_monpro_a    <= result_reg;
          r_monpro_b    <= r2_reg;
        elsif r_monpro_done = '1' then
          next_state       <= loop_s;
          next_product_reg <= p_monpro_p;
          next_result_reg  <= r_monpro_p;
        end if;
      when loop_s =>
        -- Calculate the exponentiation by multiplying powers of 2 of the message (msg^5 = msg^1 * msg^4)
        -- if get_bit(e, i):
        --     result = mon_pro(result, product, n)
        -- product = mon_pro(product, product, n)
        if first_cycle = '1' then
          -- We implement e as a shift register so only read the last bit
          if e_reg(0) = '1' then
            r_monpro_load <= '1';
            r_monpro_a    <= result_reg;
            r_monpro_b    <= product_reg;
          end if;
          p_monpro_load <= '1';
          p_monpro_a    <= product_reg;
          p_monpro_b    <= product_reg;
        elsif p_monpro_done = '1' then
          if e_reg(0) = '1' then
            next_result_reg <= r_monpro_p;
          end if;
          next_product_reg <= p_monpro_p;
          if count_done = '1' then
            next_state <= from_mongom_s;
          else
            count_en   <= '1';
            next_e_reg <= '0' & e_reg(k - 1 downto 1);
            next_state <= loop_s;
          end if;
        end if;

      when from_mongom_s =>
        -- From Montgomery space back to normal number space (right shift k bits (mod n))
        -- result = mon_pro(result, 1, n)
        if first_cycle = '1' then
          r_monpro_load <= '1';
          r_monpro_a    <= result_reg;
          r_monpro_b    <= (0 => '1', others => '0');
        elsif r_monpro_done = '1' then
          next_state      <= idle_s;
          next_done_reg   <= '1';
          next_result_reg <= r_monpro_p;
        end if;

      when others =>
        -- We reached an invalid state, go back to idle and mark whatever result we had as not correct anymore
        next_state    <= idle_s;
        next_done_reg <= '0';
    end case;
  end process;

  -- Decrementing Counter
  -- We only care about when it's done counting, the intermediate values are not important
  counter : process (rst_n, clk)
  begin
    if rst_n = '0' then
      counter_reg <= to_unsigned(k - 1, counter_reg'length);
    elsif rising_edge(clk) then
      if count_en = '1' then -- Pulse
        if counter_reg = (others => '0') then
          counter_reg <= to_unsigned(k - 1, counter_reg'length);
        else
          counter_reg <= counter_reg - 1;
        end if;
      end if;
    end if;
  end process;
  count_done <= '1' when counter_reg = (others => '0') else
                '0';

  -- Montgomery product component that does the squaring (calculating powers of 2 of the msg)
  p_monpro : MonPro
  generic map(k => k)
  port map(
    clk   => clk,
    rst_n => rst_n,
    load  => p_monpro_load,
    A     => p_monpro_a,
    B     => p_monpro_b,
    N     => monpro_n,
    done  => p_monpro_done,
    P     => p_monpro_p
  );

  -- Montgomery product component that multiplies the result by the current power of 2 of the msg.
  r_monpro : MonPro
  generic map(k => k)
  port map(
    clk   => clk,
    rst_n => rst_n,
    load  => p_monpro_load,
    A     => r_monpro_a,
    B     => r_monpro_b,
    N     => monpro_n,
    done  => r_monpro_done,
    P     => r_monpro_p
  );

end architecture;