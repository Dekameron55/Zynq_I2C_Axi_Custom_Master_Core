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
#ifndef HDC1080_H_
#define HDC1080_H_

/**
* @file hdc1080.h
* @brief This file contains the public API for the HDC1080 Temperature and
* Humidity sensor driver.
*/

#include "../i2c_axi_master/i2c_master_driver.h"
#include "xil_types.h"

/************************** Constant Definitions *****************************/

#define HDC1080_I2C_ADDR   			0x40

// Register Pointers
#define HDC1080_TEMP_REG    		0x00
#define HDC1080_HUMIDITY_REG    	0x01
#define HDC1080_CONFIG_REG 			0x02
#define HDC1080_MANUF_ID_REG		0xFE
#define HDC1080_DEVICE_ID_REG		0xFF

// Configuration bits
#define HDC1080_CONFIG_ACQ_MODE		(1 << 12) // 0 for separate, 1 for sequential
#define HDC1080_CONFIG_TRES_14BIT	0
#define HDC1080_CONFIG_TRES_11BIT	(1 << 10)
#define HDC1080_CONFIG_HRES_14BIT	0
#define HDC1080_CONFIG_HRES_11BIT	(1 << 8)
#define HDC1080_CONFIG_HRES_8BIT	(2 << 8)

// Conversion times in microseconds
#define HDC1080_CONVERSION_TIME_TEMP_14BIT		7000
#define HDC1080_CONVERSION_TIME_HUMID_14BIT		7000

/************************** Function Prototypes ******************************/

I2C_AXI_Status HDC1080_Init(I2C_AXI_Master_Driver *InstancePtr, u8 TempRes, u8 HumidRes);
I2C_AXI_Status HDC1080_GetManufacturerID(I2C_AXI_Master_Driver *InstancePtr, u16 *ManufIdPtr);
I2C_AXI_Status HDC1080_GetDeviceID(I2C_AXI_Master_Driver *InstancePtr, u16 *DeviceIdPtr);
I2C_AXI_Status HDC1080_GetTemperature(I2C_AXI_Master_Driver *InstancePtr, float *Temperature);
I2C_AXI_Status HDC1080_GetHumidity(I2C_AXI_Master_Driver *InstancePtr, float *Humidity);

#endif /* HDC1080_H_ */
