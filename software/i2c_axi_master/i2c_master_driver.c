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
* @file i2c_master_driver.c
* @brief This file contains the implementation of the functions for the custom
* AXI I2C Master driver. These functions directly interact with the hardware
* registers to perform I2C transactions.
*/

#include "i2c_master_driver.h"
#include "xil_printf.h"
#include "sleep.h"
extern volatile int transaction_complete;
extern volatile int transaction_error;

static void I2C_AXI_Master_SetSlaveAddress(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr);
static void I2C_AXI_Master_ReadFifo(I2C_AXI_Master_Driver *InstancePtr, u8 *ReadData, u16 ByteCount);
static I2C_AXI_Status I2C_AXI_WaitDoneRegUntilTimeout(I2C_AXI_Master_Driver *InstancePtr, u32 TimeoutMs);
static int I2C_AXI_Master_IsBusy(I2C_AXI_Master_Driver *InstancePtr);

/**
 * @brief Waits for the 'Done' bit in the status register to be set, with a timeout.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param TimeoutMs is the timeout duration in milliseconds.
 * @return I2C_AXI_SUCCESS if done, I2C_AXI_TIMEOUT_ERROR if timeout occurs.
 */

static I2C_AXI_Status I2C_AXI_WaitDoneRegUntilTimeout(I2C_AXI_Master_Driver *InstancePtr, u32 TimeoutMs)
{
    u32 timeout_counter = 0;
    // The hardware sets the DONE bit high when idle. We wait for it to go low (transaction start) and then high again (transaction end).
    // For simplicity in polling, we just wait for it to be high, assuming a transaction has already started.
    while ((Xil_In32(InstancePtr->BaseAddress + I2C_STATUS_REG_OFFSET) & I2C_STATUS_DONE_BIT) == 0) {
        usleep(1); // Poll every microsecond
        timeout_counter++;
        if (timeout_counter > (TimeoutMs * 1000)) {
            return I2C_AXI_TIMEOUT_ERROR;
        }
    }

    return I2C_AXI_SUCCESS;
}

/**
 * @brief Checks if the I2C core is currently busy with a transaction.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @return 1 if the core is busy, 0 if it is idle.
 */
static int I2C_AXI_Master_IsBusy(I2C_AXI_Master_Driver *InstancePtr)
{
	// The core is busy if the IDLE bit in the status register is not set.
	return (Xil_In32(InstancePtr->BaseAddress + I2C_STATUS_REG_OFFSET) & I2C_STATUS_IDLE_BIT) == 0;
}

/**
 * Initialize the I2C Master driver.
 * Sets the prescaler for ~100kHz and enables interrupts in the core.
 */
I2C_AXI_Status I2C_AXI_Master_Init(I2C_AXI_Master_Driver *InstancePtr, UINTPTR BaseAddress, I2C_SclSpeed Speed, I2C_InterruptEnable EnableInterrupts) {
    u32 prescaler;

    InstancePtr->BaseAddress = BaseAddress;
    InstancePtr->IsReady = XIL_COMPONENT_IS_READY;

    // Validate Speed parameter
    if (Speed != I2C_SCL_100KHZ && Speed != I2C_SCL_400KHZ && Speed != I2C_SCL_1MHZ) {
        return I2C_AXI_INVALID_PARAM;
    }

    // Validate EnableInterrupts parameter
    if (EnableInterrupts != I2C_INTERRUPT_DISABLE && EnableInterrupts != I2C_INTERRUPT_ENABLE) {
        return I2C_AXI_INVALID_PARAM;
    }

    // Set prescaler based on desired SCL speed (assuming 100MHz AXI clock)
    if (Speed == I2C_SCL_400KHZ) {
        // Prescaler = (100MHz / (4 * 400kHz)) - 1 = 62.5 - 1 => 61
        prescaler = 61;
    } else if (Speed == I2C_SCL_1MHZ) {
		// Prescaler = (100MHz / (4 * 1MHz)) - 1 = 25 - 1 => 24
		prescaler = 24;
	} else { // Default to 100kHz
        // Prescaler = (100MHz / (4 * 100kHz)) - 1 = 250 - 1 => 249
        prescaler = 249;
    }

    Xil_Out32(InstancePtr->BaseAddress + I2C_PRESCALER_REG_OFFSET, prescaler);

    // Only enable the 'Done' interrupt. The NACK status can be read from the ISR.
    if (EnableInterrupts == I2C_INTERRUPT_ENABLE) {
        Xil_Out32(InstancePtr->BaseAddress + I2C_IER_REG_OFFSET, I2C_INT_DONE_BIT);
    } else {
        Xil_Out32(InstancePtr->BaseAddress + I2C_IER_REG_OFFSET, 0);
    }
    // On initialization, ensure the ISR is clear.
    // Writing all 1s to a W1C (Write-1-to-Clear) register is a common way to clear all flags.
    Xil_Out32(InstancePtr->BaseAddress + I2C_ISR_REG_OFFSET, 0xFFFFFFFF);
    // Ensure the core is in a known state by clearing the done bit in the status register.
    Xil_Out32(InstancePtr->BaseAddress + I2C_ISR_REG_OFFSET, I2C_INT_DONE_BIT);

    return I2C_AXI_SUCCESS;
}

/**
 * Set the 7-bit address of the target I2C slave device.
 */
static void I2C_AXI_Master_SetSlaveAddress(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr) {
    Xil_Out32(InstancePtr->BaseAddress + I2C_SLAVE_ADDR_REG_OFFSET, SlaveAddr);
}

/**
 * @brief Issues a software reset to the I2C core logic.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 */
void I2C_AXI_Master_SoftwareReset(I2C_AXI_Master_Driver *InstancePtr) {
    // Writing the reset bit will trigger a one-cycle reset pulse in the hardware.
    Xil_Out32(InstancePtr->BaseAddress + I2C_CTRL_REG_OFFSET, I2C_CTRL_SW_RESET_BIT);
}

/**
 * Perform a blocking (polled) indexed write to the I2C bus.
 */
I2C_AXI_Status I2C_AXI_Master_Write(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *WriteData, u16 ByteCount, u32 TimeoutMs) {
    u16 bytes_to_write = ByteCount;
    I2C_AXI_Status Status;

    // Validate AddrWidth parameter
    if (AddrWidth != REG_ADDR_8_BIT && AddrWidth != REG_ADDR_16_BIT) {
        return I2C_AXI_INVALID_PARAM;
    }
    // Check if the core is busy with another transaction
    if (I2C_AXI_Master_IsBusy(InstancePtr)) {
        return I2C_AXI_BUSY;
    }

    // Set the slave address for this transaction
    I2C_AXI_Master_SetSlaveAddress(InstancePtr, SlaveAddr);

    // Load the TX FIFO with the register address (MSB first for 16-bit)
    if (AddrWidth == REG_ADDR_16_BIT) {
        Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, (RegAddr >> 8) & 0xFF);
        bytes_to_write++;
    }
    Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, RegAddr & 0xFF);
    bytes_to_write++;

    // Load the TX FIFO with the data to write
    for (int i = 0; i < ByteCount; i++) {
        Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, WriteData[i]);
    }

    // Configure the number of bytes to write
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_WRITE_REG_OFFSET, bytes_to_write);
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_READ_REG_OFFSET, 0);

    // Start the transaction
    Xil_Out32(InstancePtr->BaseAddress + I2C_CTRL_REG_OFFSET, I2C_CTRL_CMD_WRITE | I2C_CTRL_START_BIT);

    // Wait for the transaction to complete by polling
    Status = I2C_AXI_WaitDoneRegUntilTimeout(InstancePtr, TimeoutMs);
    if (Status != I2C_AXI_SUCCESS) return Status;

    // Check for ACK error
    if (Xil_In32(InstancePtr->BaseAddress + I2C_STATUS_REG_OFFSET) & I2C_STATUS_ACK_ERROR_BIT) {
        return I2C_AXI_NACK_ERROR;
    }

    return I2C_AXI_SUCCESS;
}

/**
 * Perform a non-blocking (interrupt-driven) write to the I2C bus.
 */
I2C_AXI_Status I2C_AXI_Master_Write_IT(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *WriteData, u16 ByteCount) {
    u16 bytes_to_write = ByteCount;


    // Validate AddrWidth parameter
    if (AddrWidth != REG_ADDR_8_BIT && AddrWidth != REG_ADDR_16_BIT) {
        return I2C_AXI_INVALID_PARAM;
    }
    // Check if the core is busy with another transaction
    if (I2C_AXI_Master_IsBusy(InstancePtr)) {
        return I2C_AXI_BUSY;
    }
    // Set the slave address for this transaction
    I2C_AXI_Master_SetSlaveAddress(InstancePtr, SlaveAddr);

    // Load the TX FIFO with the register address (MSB first for 16-bit)
    if (AddrWidth == REG_ADDR_16_BIT) {
        Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, (RegAddr >> 8) & 0xFF);
        bytes_to_write++;
    }
    Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, RegAddr & 0xFF);
    bytes_to_write++;

    // Load the TX FIFO with the data to write
    if (WriteData != NULL) {
        for (int i = 0; i < ByteCount; i++) {
            Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, WriteData[i]);
        }
    }

    // Configure the number of bytes to write
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_WRITE_REG_OFFSET, bytes_to_write);
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_READ_REG_OFFSET, 0);

    // Start the transaction
    Xil_Out32(InstancePtr->BaseAddress + I2C_CTRL_REG_OFFSET, I2C_CTRL_CMD_WRITE | I2C_CTRL_START_BIT);

    // This function is non-blocking, so we just return. The user must wait for the interrupt.
    // A full implementation would likely involve callbacks or other mechanisms.
    return I2C_AXI_SUCCESS;
}

/**
 * Perform a blocking (polled) write-then-read exchange on the I2C bus.
 */
I2C_AXI_Status I2C_AXI_Master_Exchange(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *ReadData, u16 ByteCount, u32 TimeoutMs) {
    u16 addr_bytes_to_write = 0;
    I2C_AXI_Status Status;

    // Validate AddrWidth parameter
    if (AddrWidth != REG_ADDR_8_BIT && AddrWidth != REG_ADDR_16_BIT) {
        return I2C_AXI_INVALID_PARAM;
    }
    // Check if the core is busy with another transaction
    if (I2C_AXI_Master_IsBusy(InstancePtr)) {
        return I2C_AXI_BUSY;
    }
    // Set the slave address for this transaction
    I2C_AXI_Master_SetSlaveAddress(InstancePtr, SlaveAddr);

    // Load the TX FIFO with the register address to read from (MSB first for 16-bit)
    if (AddrWidth == REG_ADDR_16_BIT) {
        Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, (RegAddr >> 8) & 0xFF);
        addr_bytes_to_write++;
    }
    Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, RegAddr & 0xFF);
    addr_bytes_to_write++;

    // Configure the transaction
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_WRITE_REG_OFFSET, addr_bytes_to_write);
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_READ_REG_OFFSET, ByteCount);

    // Start the transaction (Write-Then-Read)
    Xil_Out32(InstancePtr->BaseAddress + I2C_CTRL_REG_OFFSET, I2C_CTRL_CMD_WRITE_THEN_READ | I2C_CTRL_START_BIT);

    // Wait for the transaction to complete by polling
    Status = I2C_AXI_WaitDoneRegUntilTimeout(InstancePtr, TimeoutMs);

    if (Status != I2C_AXI_SUCCESS) return Status;

    // Check for ACK error
    if (Xil_In32(InstancePtr->BaseAddress + I2C_STATUS_REG_OFFSET) & I2C_STATUS_ACK_ERROR_BIT) {
        return I2C_AXI_NACK_ERROR;
    }

    // Read the data from the RX FIFO
    for (int i = 0; i < ByteCount; i++) {
        ReadData[i] = Xil_In32(InstancePtr->BaseAddress + I2C_RX_DATA_REG_OFFSET) & 0xFF;
    }

    return I2C_AXI_SUCCESS;
}

/**
 * Perform a blocking (polled) read-only transaction on the I2C bus.
 */
I2C_AXI_Status I2C_AXI_Master_Read(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u8 *ReadData, u16 ByteCount, u32 TimeoutMs) {
    I2C_AXI_Status Status;

    // Check if the core is busy with another transaction
    if (I2C_AXI_Master_IsBusy(InstancePtr)) {
        return I2C_AXI_BUSY;
    }

    // Set the slave address for this transaction
    I2C_AXI_Master_SetSlaveAddress(InstancePtr, SlaveAddr);

    // Configure the transaction for read-only
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_WRITE_REG_OFFSET, 0);
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_READ_REG_OFFSET, ByteCount);

    // Start the transaction (Read-Only)
    Xil_Out32(InstancePtr->BaseAddress + I2C_CTRL_REG_OFFSET, I2C_CTRL_CMD_READ | I2C_CTRL_START_BIT);

    // Wait for the transaction to complete by polling
    Status = I2C_AXI_WaitDoneRegUntilTimeout(InstancePtr, TimeoutMs);
    if (Status != I2C_AXI_SUCCESS) return Status;

    // Check for ACK error (though less common on a pure read)
    if (Xil_In32(InstancePtr->BaseAddress + I2C_STATUS_REG_OFFSET) & I2C_STATUS_ACK_ERROR_BIT) {
        return I2C_AXI_NACK_ERROR;
    }

    // Read the data from the RX FIFO
    I2C_AXI_Master_ReadFifo(InstancePtr, ReadData, ByteCount);

    return I2C_AXI_SUCCESS;
}

/**
 * Reads a specified number of bytes from the RX FIFO.
 */
static void I2C_AXI_Master_ReadFifo(I2C_AXI_Master_Driver *InstancePtr, u8 *ReadData, u16 ByteCount) {
    for (int i = 0; i < ByteCount; i++) {
        ReadData[i] = Xil_In32(InstancePtr->BaseAddress + I2C_RX_DATA_REG_OFFSET) & 0xFF;
    }
}

/**
 * Perform a non-blocking, interrupt-driven, write-then-read exchange on the I2C bus.
 * This function starts the transaction and returns immediately.
 */
I2C_AXI_Status I2C_AXI_Master_Exchange_IT(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *ReadData, u16 ByteCount) {
    u16 addr_bytes_to_write = 0;

    // Store the number of bytes for the ISR/callback
    InstancePtr->NumBytes = ByteCount;
    InstancePtr->DataBufferPtr = ReadData;

    // Validate AddrWidth parameter
    if (AddrWidth != REG_ADDR_8_BIT && AddrWidth != REG_ADDR_16_BIT) {
        return I2C_AXI_INVALID_PARAM;
    }
    // Check if the core is busy with another transaction
    if (I2C_AXI_Master_IsBusy(InstancePtr)) {
        return I2C_AXI_BUSY;
    }
    // Set the slave address for this transaction
    I2C_AXI_Master_SetSlaveAddress(InstancePtr, SlaveAddr);

    // Load the TX FIFO with the register address to read from (MSB first for 16-bit)
    if (AddrWidth == REG_ADDR_16_BIT) {
        Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, (RegAddr >> 8) & 0xFF);
        addr_bytes_to_write++;
    }
    Xil_Out32(InstancePtr->BaseAddress + I2C_TX_DATA_REG_OFFSET, RegAddr & 0xFF);
    addr_bytes_to_write++;

    // Configure the transaction
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_WRITE_REG_OFFSET, addr_bytes_to_write);
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_READ_REG_OFFSET, ByteCount);

    // Start the transaction (Write-Then-Read)
    Xil_Out32(InstancePtr->BaseAddress + I2C_CTRL_REG_OFFSET, I2C_CTRL_CMD_WRITE_THEN_READ | I2C_CTRL_START_BIT);

    return I2C_AXI_SUCCESS;
}

/**
 * Perform a blocking, interrupt-driven, write-then-read exchange on the I2C bus.
 * This function starts the transaction, waits for the interrupt, and reads the data.
 */
I2C_AXI_Status I2C_AXI_Master_Exchange_Interrupt(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *ReadData, u16 ByteCount)
{
	I2C_AXI_Status Status;

	// Start the non-blocking transaction
	Status = I2C_AXI_Master_Exchange_IT(InstancePtr, SlaveAddr, RegAddr, AddrWidth, ReadData, ByteCount);
	if (Status != I2C_AXI_SUCCESS) {
		return Status;
	}

    // Reset the software flags before starting
	transaction_complete = 0;
	transaction_error = 0;

    // Wait for the transaction to complete. The ISR will set one of the flags.
    while(transaction_complete == 0 && transaction_error == 0);

    if (transaction_error) {
        return I2C_AXI_NACK_ERROR;
    }

    return I2C_AXI_SUCCESS;
}

/**
 * Perform a non-blocking, interrupt-driven, read-only transaction on the I2C bus.
 */
I2C_AXI_Status I2C_AXI_Master_Read_IT(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u8 *ReadData, u16 ByteCount) {

    // Store the number of bytes for the ISR/callback
    InstancePtr->NumBytes = ByteCount;
    InstancePtr->DataBufferPtr = ReadData;
    // Check if the core is busy with another transaction
    if (I2C_AXI_Master_IsBusy(InstancePtr)) {
        return I2C_AXI_BUSY;
    }
    // Set the slave address for this transaction
    I2C_AXI_Master_SetSlaveAddress(InstancePtr, SlaveAddr);

    // Configure the transaction for read-only
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_WRITE_REG_OFFSET, 0);
    Xil_Out32(InstancePtr->BaseAddress + I2C_BYTES_READ_REG_OFFSET, ByteCount);

    // Start the transaction (Read-Only)
    Xil_Out32(InstancePtr->BaseAddress + I2C_CTRL_REG_OFFSET, I2C_CTRL_CMD_READ | I2C_CTRL_START_BIT);

    return I2C_AXI_SUCCESS;
}

/**
 * Perform a blocking, interrupt-driven, read-only transaction on the I2C bus.
 * This function starts the transaction, waits for the interrupt, and reads the data.
 */
I2C_AXI_Status I2C_AXI_Master_Read_Interrupt(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u8 *ReadData, u16 ByteCount)
{
	I2C_AXI_Status Status;

	// Start the non-blocking transaction
	Status = I2C_AXI_Master_Read_IT(InstancePtr, SlaveAddr, ReadData, ByteCount);
	if (Status != I2C_AXI_SUCCESS) {
		return Status;
	}

    // Reset the software flags before starting
	transaction_complete = 0;
	transaction_error = 0;

    // Wait for the transaction to complete. The ISR will set one of the flags.
    while(transaction_complete == 0 && transaction_error == 0);

    if (transaction_error) {
        return I2C_AXI_NACK_ERROR;
    }

    return I2C_AXI_SUCCESS;
}

void I2C_AXI_Master_SetHandler(I2C_AXI_Master_Driver *InstancePtr, I2C_AXI_Handler FuncPtr, void *CallBackRef)
{
	InstancePtr->Handler = FuncPtr;
	InstancePtr->CallBackRef = CallBackRef;
}

/**
 * The Interrupt Service Routine (ISR) for the I2C Master.
 * This function will be connected to the interrupt controller.
 */
void I2C_AXI_Master_InterruptHandler(void *InstancePtr) {
    I2C_AXI_Master_Driver *I2cInst = (I2C_AXI_Master_Driver *)InstancePtr;

    // Read the Interrupt Status Register to know what caused the interrupt
    u32 isr_status = Xil_In32(I2cInst->BaseAddress + I2C_ISR_REG_OFFSET);

    // Handle the event flags and data transfer
    if (isr_status & I2C_INT_DONE_BIT) {
        // If the transaction was a read, copy the data from the FIFO
        if (I2cInst->NumBytes > 0 && I2cInst->DataBufferPtr != NULL) {
            I2C_AXI_Master_ReadFifo(I2cInst, I2cInst->DataBufferPtr, I2cInst->NumBytes);
        }
        transaction_complete = 1;
    }
    if (isr_status & I2C_INT_ACK_ERROR_BIT) {
        transaction_error = 1;
    }

    // If the user has registered a handler, call it.
    if (I2cInst->Handler) {
    	I2cInst->Handler(I2cInst->CallBackRef, isr_status, I2cInst->NumBytes, I2cInst->DataBufferPtr);
    }

    // Clear the handled interrupts by writing back the read status (W1C)
    Xil_Out32(I2cInst->BaseAddress + I2C_ISR_REG_OFFSET, isr_status);
}
