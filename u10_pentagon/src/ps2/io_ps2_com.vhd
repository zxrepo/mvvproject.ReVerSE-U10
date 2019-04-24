-----------------------------------------------------------------[Rev.20110213]
-- PS/2 lowlevel driver
-------------------------------------------------------------------------------
-- clockFilter  - Number of clock cycles used in filtering the PS/2 clock.
--                This suppresses transient and echo effects on the cable.
--                Recommended value is 15.
-- ticksPerUsec - Fill in the system clock speed in Mhz.
-- clk          - system clock input
-- ps2_clk_in   - Clock input from the ps/2 port
-- ps2_dat_in   - Data input from the ps/2 port
-- ps2_clk_out  - Generated ps/2 clock route to open-collector logic.
-- ps2_dat_out  - Generated ps/2 data line route to open-collector logic.
-- inIdle       - Output is high when driver is waiting/idle.
-- sendTrigger  - Make this signal 1 clock cycle high to send byte
-- sendByte     - Actual byte send when sendTrigger is given
-- recvTrigger  - Is 1 clock cycle high when byte is received.
-- recvByte     - Last byte received from the ps/2 interface

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity io_ps2_com is
	generic (
		clockFilter : integer;
		ticksPerUsec : integer );
	port (
		clk: in std_logic;
		reset : in std_logic;
		ps2_clk_in: in std_logic;
		ps2_dat_in: in std_logic;
		ps2_clk_out: out std_logic;
		ps2_dat_out: out std_logic;
		
		inIdle : out std_logic;

		sendTrigger : in std_logic;
		sendByte : in unsigned(7 downto 0);
		sendBusy : out std_logic;
		recvTrigger : out std_logic;
		recvByte : out unsigned(10 downto 0) );
end entity;

architecture rtl of io_ps2_com is
	constant ticksPer100Usec : integer := ticksPerUsec * 100;
	type comStateDef is (
		stateIdle, stateWait100, stateWaitClockLow, stateWaitClockHigh, stateClockAndDataLow, stateWaitAck,
		stateRecvBit, stateWaitHighRecv);
	signal comState : comStateDef := stateIdle;

	signal sendTriggerLoc : std_logic := '0';
	signal clkReg: std_logic := '1';
	signal clkFilterCnt: integer range 0 to clockFilter;

	signal waitCount : integer range 0 to ticksPer100Usec := 0;
	signal currentBit : std_logic;
	signal bitCount : unsigned(3 downto 0);
	signal parity : std_logic;

	signal recvByteLoc : unsigned(10 downto 0);
begin
	inIdle <= '1' when comState = stateIdle else '0';
	sendBusy <= sendTrigger or sendTriggerLoc;

-- Noise and glitch filter on the clock-line
	process(clk)
	begin
		if rising_edge(clk) then
			clkReg <= ps2_clk_in;
			if clkReg /= ps2_clk_in then
				clkFilterCnt <= clockFilter;
			elsif clkFilterCnt /= 0 then
				clkFilterCnt <= clkFilterCnt - 1;
			end if;
		end if;
	end process;

-- Lowlevel send and receive state machines
	process(clk)
	begin
		if rising_edge(clk) then
			ps2_clk_out <= '1';
			ps2_dat_out <= '1';
			recvTrigger <= '0';
			if waitCount /= 0 then
				waitCount <= waitCount - 1;
			end if;

			if sendTrigger = '1' then
				sendTriggerLoc <= '1';
			end if;
			
			case comState is
			when stateIdle =>
				bitCount <= (others => '0');
				parity <= '1';
				if sendTriggerLoc = '1' then
					waitCount <= ticksPer100Usec;
					comState <= stateWait100;
				end if;
				if (clkReg = '0') and (clkFilterCnt = 0) then
					comState <= stateRecvBit;
				end if;
			-- Host announces its wish to send by pulling clock low for 100us
			when stateWait100 =>
				ps2_clk_out <= '0';
				if waitCount = 0 then
					comState <= stateClockAndDataLow;
					waitCount <= ticksPerUsec * 10;
				end if;
			-- Pull data low while keeping clock low. This is host->device start bit.
			-- Now the device will take over and provide the clock so host must release.
			-- Next state is waitClockHigh to check that clock indeed is released
			when stateClockAndDataLow =>
				ps2_clk_out <= '0';
				ps2_dat_out <= '0';
				if waitCount = 0 then
					currentBit <= '0';
					comState <= stateWaitClockHigh;
				end if;
			-- Wait for 0->1 transition on clock for send.
			-- The device reads current bit while clock is low.
			when stateWaitClockHigh =>
				ps2_dat_out <= currentBit;
				if (clkReg = '1') and (clkFilterCnt = 0) then
					comState <= stateWaitClockLow;
				end if;
			-- Wait for 1->0 transition on clock for send
			-- Host can now change the data line for next bit.
			when stateWaitClockLow =>
				ps2_dat_out <= currentBit;
				if (clkReg = '0') and (clkFilterCnt = 0) then
					if bitCount = 10 then
						comState <= stateWaitAck;
					elsif bitCount = 9 then
						-- Send stop bit
						currentBit <= '1';
						comState <= stateWaitClockHigh;
						bitCount <= bitCount + 1;
					elsif bitCount = 8 then
						-- Send parity bit
						currentBit <= parity;
						comState <= stateWaitClockHigh;
						bitCount <= bitCount + 1;
					else
						currentBit <= sendByte(to_integer(bitCount));
						parity <= parity xor sendByte(to_integer(bitCount));
						comState <= stateWaitClockHigh;
						bitCount <= bitCount + 1;
					end if;
				end if;
			-- Transmission of byte done, wait for ack from device then return to idle.
			when stateWaitAck =>
				if (clkReg = '1') and (clkFilterCnt = 0) then
					sendTriggerLoc <= '0';
					comState <= stateIdle;
				end if;
			-- Receive a single bit.
			when stateRecvBit =>
				if (clkReg = '0') and (clkFilterCnt = 0) then
					recvByteLoc <= ps2_dat_in & recvByteLoc(recvByteLoc'high downto 1);
					bitCount <= bitCount + 1;
					comState <= stateWaitHighRecv;
				end if;
			-- Wait for 0->1 transition on clock for receive.
			when stateWaitHighRecv =>
				if (clkReg = '1') and (clkFilterCnt = 0) then
					comState <= stateRecvBit;
					if bitCount = 11 then
						recvTrigger <= '1';
						recvByte <= recvByteLoc;
						comState <= stateIdle;
					end if;
				end if;
			end case;
			
			if reset = '1' then
				comState <= stateIdle;
				sendTriggerLoc <= '0';
			end if;
		end if;
	end process;
end architecture;