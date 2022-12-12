-- Copyright 2022 SmartThings
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local SensorMultilevel = (require "st.zwave.CommandClass.SensorMultilevel")({ version = 1 })
local ThermostatSetpoint = (require "st.zwave.CommandClass.ThermostatSetpoint")({ version = 1 })
local ThermostatMode = (require "st.zwave.CommandClass.ThermostatMode")({ version = 1 })
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version = 1 })
local Clock = (require "st.zwave.CommandClass.Clock")({ version = 1 })
local capabilities = require "st.capabilities"
local ZwaveDriver = require "st.zwave.driver"
local defaults = require "st.zwave.defaults"
local cc = require "st.zwave.CommandClass"
local log = require "log"
local constants = require "st.zwave.constants"
local utils = require "st.utils"
local delay_send = require "delay_send"
local WEEK = {1, 2, 3, 4, 5, 6, 0}

local ZWAVE_THERMOSTAT_FINGERPRINTS = {
  {mfr = 0x0060, prod = 0x0001, model = 0x0015} -- Everspring AC301
}

local CONFIG_PARAMS = {}

local function can_handle_zwave_thermostat(opts, driver, device, ...)
  for _, fingerprint in ipairs(ZWAVE_THERMOSTAT_FINGERPRINTS) do
    if device:id_match(fingerprint.mfr, fingerprint.prod, fingerprint.model) then
      return true
    end
  end
  return false
end

local function refresh(driver,device)
  log.debug('Refresh')
  
  local offset = ((device.preferences or {}).timezoneUTC or 0) + ((device.preferences or {}).timezoneDST or 0)
  local now = os.date('*t', os.time() + offset * 60 * 60)
	
  local cmds = {
    Clock:Set({ weekday = (now.wday + 5) % 7, hour = now.hour, minute = now.min }),
    Clock:Get({}),
    ThermostatFanMode:SupportedGet({}),
    ThermostatMode:SupportedGet({}),
    Configuration:Get({ parameter_number = 132 }),  -- Hold = 0, Run Schedule = 1
    Configuration:Get({ parameter_number = 25 }),   -- Energy save on = 2, off = 0
    ThermostatFanMode:Get({}),
    ThermostatMode:Get({}),
    ThermostatOperatingState:Get({}),
    ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1}),
    ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.COOLING_1}),
    SensorMultilevel:Get({}),
  }
  delay_send(device,cmds,1)
end

local function dev_init(driver, device)
  log.debug('Device Init')
  refresh(driver,device)
end

local function set_heating_setpoint(driver, device, command)
  local scale = device:get_field(constants.TEMPERATURE_SCALE)
  local loc_scale = device.state_cache.main.thermostatHeatingSetpoint.heatingSetpoint.unit
  local value = command.args.setpoint
  local set = ThermostatSetpoint:Set({
    setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1,
    scale = scale,
    value = value
  })
  device:send_to_component(set, command.component)

  local follow_up_poll = function()
    device:send_to_component(
      ThermostatSetpoint:Get({setpoint_type = ThermostatSetpoint.setpoint_type.HEATING_1}),
      command.component
    )
  end

  device.thread:call_with_delay(1, follow_up_poll)
end

defaults.register_for_default_handlers(driver_template, driver_template.supported_capabilities)
local thermostat = ZwaveDriver("zwave-thermostat", driver_template)
thermostat:run()
  device.thread:call_with_delay(1, follow_up_poll)
end
