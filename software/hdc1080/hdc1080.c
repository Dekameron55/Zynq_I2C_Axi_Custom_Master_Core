/******************************************************************************
*
* Copyright (C) 2025
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY,
* WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF
* OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*
******************************************************************************/
#include "hdc1080.h"
#include "sleep.h"

/**
* @file hdc1080.c
* @brief This file contains the implementation of the functions for the HDC1080
* sensor driver. It uses the low-level I2C master driver for communication.
*/

/**
 * Initializes the HDC1080 sensor by writing to its configuration register.
 */
I2C_AXI_Status HDC1080_Init(I2C_AXI_Master_Driver *InstancePtr, u8 TempRes, u8 HumidRes)
{
    I2C_AXI_Status Status;
    // The configuration value is two bytes, but the I2C_AXI_Master_Write function
    // expects a u8 pointer for the data. We create an array to hold the bytes.
    u8 config_data[2];
    u16 config_value = 0;

    // Set temperature and humidity resolution bits
    if (TempRes == 11) config_value |= HDC1080_CONFIG_TRES_11BIT;
    if (HumidRes == 11) config_value |= HDC1080_CONFIG_HRES_11BIT;
    if (HumidRes == 8)  config_value |= HDC1080_CONFIG_HRES_8BIT;

    // Validate that the user has provided valid resolution values.
    // The HDC1080 only supports 14-bit and 11-bit for temperature, and 14, 11, 8 for humidity.
    if (!((TempRes == 14 || TempRes == 11) && (HumidRes == 14 || HumidRes == 11 || HumidRes == 8))) {
        return I2C_AXI_INVALID_PARAM;
    }

    // The sensor expects the data MSB first.
    config_data[0] = (config_value >> 8) & 0xFF;
    config_data[1] = config_value & 0xFF;

    // A 15ms delay is required after power-up before communication.
    usleep(15000);

    // Write the configuration to the sensor.
    Status = I2C_AXI_Master_Write(InstancePtr, HDC1080_I2C_ADDR, HDC1080_CONFIG_REG, REG_ADDR_8_BIT, config_data, 2, I2C_AXI_TIMEOUT_MAX);
    if (Status != I2C_AXI_SUCCESS) {
        return Status; // Propagate the specific error (e.g., NACK) from the write function.
    }

    return I2C_AXI_SUCCESS;
}

/**
 * Reads the Manufacturer ID from the HDC1080 sensor.
 */
I2C_AXI_Status HDC1080_GetManufacturerID(I2C_AXI_Master_Driver *InstancePtr, u16 *ManufIdPtr)
{
    I2C_AXI_Status Status;
    u8 read_buffer[2];

    // Use the blocking (polled) exchange function.
    Status = I2C_AXI_Master_Exchange(InstancePtr, HDC1080_I2C_ADDR, HDC1080_MANUF_ID_REG, REG_ADDR_8_BIT, read_buffer, 2, I2C_AXI_TIMEOUT_MAX);
    if (Status != I2C_AXI_SUCCESS) {
        return Status;
    }

    // Combine the two bytes (MSB first)
    *ManufIdPtr = (read_buffer[0] << 8) | read_buffer[1];
    return I2C_AXI_SUCCESS;
}

/**
 * Reads the Device ID from the HDC1080 sensor.
 */
I2C_AXI_Status HDC1080_GetDeviceID(I2C_AXI_Master_Driver *InstancePtr, u16 *DeviceIdPtr)
{
    I2C_AXI_Status Status;
    u8 read_buffer[2];

    // Use the blocking (polled) exchange function.
    Status = I2C_AXI_Master_Exchange(InstancePtr, HDC1080_I2C_ADDR, HDC1080_DEVICE_ID_REG, REG_ADDR_8_BIT, read_buffer, 2, I2C_AXI_TIMEOUT_MAX);
    if (Status != I2C_AXI_SUCCESS) {
        return Status;
    }

    // Combine the two bytes (MSB first)
    *DeviceIdPtr = (read_buffer[0] << 8) | read_buffer[1];
    return I2C_AXI_SUCCESS;
}

/**
 * Reads the Temperature from the HDC1080 sensor.
 */
I2C_AXI_Status HDC1080_GetTemperature(I2C_AXI_Master_Driver *InstancePtr, float *Temperature)
{
    I2C_AXI_Status Status;
    u8 read_buffer[2];
    u16 raw_temp;
    u8 pointer_reg = HDC1080_TEMP_REG;

    // 1. Trigger a measurement by writing the temperature register pointer.
    //    This is a write with no data payload.
    Status = I2C_AXI_Master_Write(InstancePtr, HDC1080_I2C_ADDR, pointer_reg, REG_ADDR_8_BIT, NULL, 0, I2C_AXI_TIMEOUT_MAX);
    if (Status != I2C_AXI_SUCCESS) {
        return Status;
    }
    // 2. Wait for the conversion to complete.
    usleep(HDC1080_CONVERSION_TIME_TEMP_14BIT);

    // 3. Read the 2-byte result. This is a true read-only transaction.
    Status = I2C_AXI_Master_Read(InstancePtr, HDC1080_I2C_ADDR, read_buffer, 2, I2C_AXI_TIMEOUT_MAX);
    if (Status != I2C_AXI_SUCCESS) {
        return Status;
    }

    raw_temp = (read_buffer[0] << 8) | read_buffer[1];
    *Temperature = ((float)raw_temp / 65536.0) * 165.0 - 40.0;

    return I2C_AXI_SUCCESS;
}

/**
 * Reads the Humidity from the HDC1080 sensor.
 */
I2C_AXI_Status HDC1080_GetHumidity(I2C_AXI_Master_Driver *InstancePtr, float *Humidity)
{
    I2C_AXI_Status Status;
    u8 read_buffer[2];
    u16 raw_humid;
    u8 pointer_reg = HDC1080_HUMIDITY_REG;

    // 1. Trigger a measurement by writing the humidity register pointer.
    Status = I2C_AXI_Master_Write(InstancePtr, HDC1080_I2C_ADDR, pointer_reg, REG_ADDR_8_BIT, NULL, 0, I2C_AXI_TIMEOUT_MAX);
    if (Status != I2C_AXI_SUCCESS) {
        return Status;
    }

    // 2. Wait for the conversion to complete.
    usleep(HDC1080_CONVERSION_TIME_HUMID_14BIT);

    // 3. Read the 2-byte result.
    Status = I2C_AXI_Master_Read(InstancePtr, HDC1080_I2C_ADDR, read_buffer, 2, I2C_AXI_TIMEOUT_MAX);
    if (Status != I2C_AXI_SUCCESS) {
        return Status;
    }

    raw_humid = (read_buffer[0] << 8) | read_buffer[1];
    *Humidity = ((float)raw_humid / 65536.0) * 100.0;

    return I2C_AXI_SUCCESS;
}
