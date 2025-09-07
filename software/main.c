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

/**
* @file main.c
* @brief This is the main application file. It initializes the system, including
* the I2C master and the HDC1080 sensor, and then enters a loop to
* continuously read and display sensor data.
*/

#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xscugic.h"
#include "xil_exception.h"
#include "i2c_axi_master/i2c_master_driver.h"
#include "hdc1080/hdc1080.h"
#include "sleep.h"

/************************** Constant Definitions *****************************/
// Define this to 1 to enable interrupt-related debug prints
#define DEBUG_IT 1

/************************** Function Prototypes ******************************/
I2C_AXI_Status SetupInterruptSystem(XScuGic *IntcInstancePtr, I2C_AXI_Master_Driver *I2cInstancePtr);
void MyI2cEventHandler(void *CallBackRef, u32 Event, u16 ByteCount, u8 *DataPtr);
void print_float(float f);

/************************** Global Variables *********************************/
I2C_AXI_Master_Driver i2c_master_inst;
XScuGic intc; // Interrupt Controller Instance

// These flags are used to signal the main loop that a transaction is complete.
// The 'volatile' keyword is essential to prevent the compiler from optimizing
// away checks in the main loop.
volatile int transaction_complete;
volatile int transaction_error;

int main()
{
    I2C_AXI_Status Status;
    u32 dummy_read_data;
    u32 version_data;
    u16 manuf_id;
    u16 device_id;
    float temperature;
    float humidity;

    init_platform();

    xil_printf("--- I2C Master Sanity Test ---\n\r");

    // For this test, we will use polled functions, so interrupts can be disabled.
    Status = I2C_AXI_Master_Init(&i2c_master_inst, XPAR_AXI_I2C_MASTER_0_BASEADDR, I2C_SCL_100KHZ, I2C_INTERRUPT_DISABLE);
    if (Status != I2C_AXI_SUCCESS) {
        xil_printf("I2C Master Initialization Failed\n\r");
        return XST_FAILURE;
    }
    xil_printf("I2C Master Initialized Successfully\n\r");

    // Issue a software reset to ensure the core is in a known state.
    I2C_AXI_Master_SoftwareReset(&i2c_master_inst);
    xil_printf("I2C Master Core Reset.\n\r");

    // --- Test Dummy Register ---
    xil_printf("Testing Dummy Register...\n\r");
    Xil_Out32(i2c_master_inst.BaseAddress + I2C_DUMMY_REG_OFFSET, 0xDEADBEEF);
    dummy_read_data = Xil_In32(i2c_master_inst.BaseAddress + I2C_DUMMY_REG_OFFSET);

    if (dummy_read_data != 0xDEADBEEF) {
        xil_printf("  ERROR: Dummy Register test FAILED! Wrote 0xDEADBEEF, read back 0x%08X\n\r", dummy_read_data);
    } else {
        xil_printf("  SUCCESS: Dummy Register test passed.\n\r");
    }

    // --- Read Version Register ---
    xil_printf("Reading Version Register...\n\r");
    version_data = Xil_In32(i2c_master_inst.BaseAddress + I2C_VERSION_REG_OFFSET);

    if (version_data != 0x00010200) {
         xil_printf("  ERROR: Version Register test FAILED! Expected 0x00010200, read back 0x%08X\n\r", version_data);
    } else {
         xil_printf("  SUCCESS: Version Register test passed. Read back 0x%08X\n\r", version_data);
    }


	// Initialize the HDC1080 Sensor
	Status = HDC1080_Init(&i2c_master_inst, 14, 14); // 14-bit resolution for both
	if (Status == I2C_AXI_SUCCESS) {
		xil_printf("HDC1080 Sensor Initialized Successfully\n\r");
	} else {
		xil_printf("HDC1080 Sensor Init Failed %d\n\r", Status);
	}

    // --- Main Application Loop ---
    xil_printf("\n--- Starting main application loop ---\n\r");

    while(1) {
		// Read and verify Manufacturer ID
		Status = HDC1080_GetManufacturerID(&i2c_master_inst, &manuf_id);

		if (Status != I2C_AXI_SUCCESS) {
			xil_printf("  ERROR: Failed to read Manufacturer ID. Status: %d\n\r", Status);
		} else {
			xil_printf("  Manufacturer ID: 0x%04X\n\r", manuf_id);
			if (manuf_id != 0x5449) {
				xil_printf("  WARNING: Manufacturer ID does not match expected 0x5449!\n\r");
			}
		}

		// Read and verify Device ID
		Status = HDC1080_GetDeviceID(&i2c_master_inst, &device_id);
		if (Status != I2C_AXI_SUCCESS) {
			xil_printf("  ERROR: Failed to read Device ID. Status: %d\n\r", Status);
		} else {
			xil_printf("  Device ID: 0x%04X\n\r", device_id);
			if (device_id != 0x1050) {
				xil_printf("  WARNING: Device ID does not match expected 0x1050!\n\r");
			}
		}

		// Read and print Temperature
		Status = HDC1080_GetTemperature(&i2c_master_inst, &temperature);
		if (Status != I2C_AXI_SUCCESS) {
			xil_printf("  ERROR: Failed to read temperature. Status: %d\n\r", Status);
		} else {
			xil_printf("  Temperature: "); print_float(temperature); xil_printf(" C\n\r");
		}

		// Read and print Humidity
		Status = HDC1080_GetHumidity(&i2c_master_inst, &humidity);
		if (Status != I2C_AXI_SUCCESS) {
			xil_printf("  ERROR: Failed to read humidity. Status: %d\n\r", Status);
		} else {
			xil_printf("  Humidity: "); print_float(humidity); xil_printf("%%\n\r");
		}

		sleep(1);
    }

    cleanup_platform();
    return 0;
}

I2C_AXI_Status SetupInterruptSystem(XScuGic *IntcInstancePtr, I2C_AXI_Master_Driver *I2cInstancePtr)
{
    int Status;
    XScuGic_Config *IntcConfig;

    // Initialize the interrupt controller driver
    IntcConfig = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if (NULL == IntcConfig) return I2C_AXI_FAILURE;

    Status = XScuGic_CfgInitialize(IntcInstancePtr, IntcConfig, IntcConfig->CpuBaseAddress);
    if (Status != XST_SUCCESS) return I2C_AXI_FAILURE;

    // Connect the device driver handler that will be called when an interrupt for the device occurs
    Status = XScuGic_Connect(IntcInstancePtr, XPAR_FABRIC_AXI_I2C_MASTER_0_INTERRUPT_INTR, (Xil_ExceptionHandler)I2C_AXI_Master_InterruptHandler, (void *)I2cInstancePtr);
    if (Status != XST_SUCCESS) return I2C_AXI_FAILURE;

    // Enable the interrupt for the I2C device
    XScuGic_Enable(IntcInstancePtr, XPAR_FABRIC_AXI_I2C_MASTER_0_INTERRUPT_INTR);

    // Initialize the exception table and register the interrupt controller handler
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT, (Xil_ExceptionHandler)XScuGic_InterruptHandler, IntcInstancePtr);
    Xil_ExceptionEnable(); // Enable non-critical exceptions

    return I2C_AXI_SUCCESS;
}

/**
 * Prints a floating-point number with 2 decimal places using xil_printf.
 * @param f The float to print.
 */
void print_float(float f)
{
    int integer_part = (int)f;
    int fractional_part = (int)((f - integer_part) * 100);

    // Handle negative numbers
    if (f < 0 && fractional_part < 0) {
        fractional_part = -fractional_part;
    }

    xil_printf("%d.", integer_part);

    // Print leading zero if necessary
    if (fractional_part < 10) xil_printf("0");
    xil_printf("%d", fractional_part);
}

/**
 * @brief The application-level event handler for I2C interrupts.
 * @param CallBackRef is a pointer to the I2C driver instance.
 * @param Event is the status from the ISR, indicating what occurred.
 */
void MyI2cEventHandler(void *CallBackRef, u32 Event, u16 ByteCount, u8 *DataPtr)
{
#if (DEBUG_IT == 1)
	// This debug print shows the power of the callback: the application's handler
	// now knows how many bytes were associated with the completed transaction.
	xil_printf("DEBUG: MyI2cEventHandler called with event: 0x%02X, ByteCount: %d, DataPtr: 0x%08X\n\r",
			   Event,
			   ByteCount,
			   (unsigned int)DataPtr
			   );

	// The main ISR in the driver now handles setting the transaction_complete
	// and transaction_error flags, as well as reading the FIFO.
	// This user callback is now only for application-specific notifications.
#endif
}
