/******************************************************************************
*
* Copyright (C) 2023 - DekameronBG
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
* @file i2c_master_driver.h
* @brief This file contains the public API for the custom AXI I2C Master driver.
* It includes register offsets, function prototypes, and type definitions for
* interacting with the I2C hardware core.
*/

#ifndef I2C_MASTER_DRIVER_H_
#define I2C_MASTER_DRIVER_H_

#include "xil_types.h"
#include "xil_io.h"
#include "xstatus.h"

// Register Offsets (from axi_i2c_master.v)
#define I2C_CTRL_REG_OFFSET         0x00
#define I2C_STATUS_REG_OFFSET       0x04
#define I2C_SLAVE_ADDR_REG_OFFSET   0x08
#define I2C_BYTES_WRITE_REG_OFFSET  0x0C
#define I2C_BYTES_READ_REG_OFFSET   0x10
#define I2C_PRESCALER_REG_OFFSET    0x14
#define I2C_IER_REG_OFFSET          0x18
#define I2C_ISR_REG_OFFSET          0x1C
#define I2C_DUMMY_REG_OFFSET        0x20
#define I2C_VERSION_REG_OFFSET      0x24
#define I2C_TX_DATA_REG_OFFSET      0x40
#define I2C_RX_DATA_REG_OFFSET      0x80

// Control Register bits
#define I2C_CTRL_CMD_WRITE          0x01
#define I2C_CTRL_CMD_READ           0x02
#define I2C_CTRL_CMD_WRITE_THEN_READ 0x03
#define I2C_CTRL_SW_RESET_BIT       0x04  // Bit 2 for software reset
#define I2C_CTRL_START_BIT          0x100

// Status Register bits
#define I2C_STATUS_ACK_ERROR_BIT    0x01
#define I2C_STATUS_DONE_BIT         0x02
#define I2C_STATUS_IDLE_BIT         0x04 // Bit 2 is the level-sensitive Idle status

// Interrupt Register bits (IER and ISR)
#define I2C_INT_ACK_ERROR_BIT       0x01
#define I2C_INT_DONE_BIT            0x02

// Default timeout for polled functions in milliseconds
#define I2C_AXI_TIMEOUT_MAX			500

/**
 * Enum to specify the width of the register address for a transaction.
 */
typedef enum {
    REG_ADDR_8_BIT,
    REG_ADDR_16_BIT
} I2C_RegAddrWidth;

/**
 * Enum to specify the I2C SCL clock speed.
 */
typedef enum {
    I2C_SCL_100KHZ,
    I2C_SCL_400KHZ,
    I2C_SCL_1MHZ
} I2C_SclSpeed;

/**
 * Enum to specify driver status codes.
 */
typedef enum {
    I2C_AXI_SUCCESS = 0,
    I2C_AXI_FAILURE = 1,
    I2C_AXI_NACK_ERROR = 2,
	I2C_AXI_TIMEOUT_ERROR = 3,
    I2C_AXI_INVALID_PARAM = 4,
    I2C_AXI_BUSY = 5
} I2C_AXI_Status;

/**
 * Enum to specify whether to enable interrupts in the core.
 */
typedef enum {
    I2C_INTERRUPT_DISABLE,
    I2C_INTERRUPT_ENABLE
} I2C_InterruptEnable;


struct I2C_AXI_Master_Driver; // Forward declaration

/**
 * @brief Callback function type for handling asynchronous events.
 * @param CallBackRef is a pointer to the upper-layer data instance.
 * @param Event is the event that occurred (e.g., I2C_INT_DONE_BIT).
 * @param ByteCount is the number of bytes involved in the transaction.
 * @param DataPtr is a pointer to the data buffer associated with the transaction.
 */
typedef void (*I2C_AXI_Handler)(void *CallBackRef, u32 Event, u16 ByteCount, u8 *DataPtr);

/**
 * Driver instance data. The user is required to allocate a variable
 * of this type for every I2C master device in the system.
 */
typedef struct I2C_AXI_Master_Driver {
    UINTPTR BaseAddress;      // Base address of the device
    u32 IsReady;              // Device is initialized and ready
	I2C_AXI_Handler Handler;   // Callback function for event handling
	void *CallBackRef;         // Pointer to be passed to the callback
	u16 NumBytes;             // Number of bytes for the current transaction
	u8 *DataBufferPtr;        // Pointer to the user's data buffer
} I2C_AXI_Master_Driver;


/************************** Function Prototypes ******************************/

/**
 * @brief Issues a software reset to the I2C core logic.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 */
void I2C_AXI_Master_SoftwareReset(I2C_AXI_Master_Driver *InstancePtr);

/**
 * @brief Initialize the I2C Master driver.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param BaseAddress is the base address of the I2C Master core.
 * @param Speed is the desired SCL clock speed (100kHz or 400kHz).
 * @param EnableInterrupts specifies whether to enable interrupts in the core.
 * @return I2C_AXI_SUCCESS if initialization was successful, else I2C_AXI_INVALID_PARAM.
 */
I2C_AXI_Status I2C_AXI_Master_Init(I2C_AXI_Master_Driver *InstancePtr, UINTPTR BaseAddress, I2C_SclSpeed Speed, I2C_InterruptEnable EnableInterrupts);

/**
 * @brief Perform a blocking (polled) indexed write to the I2C bus.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param SlaveAddr is the 7-bit address of the target slave device.
 * @param RegAddr is the register address to write to.
 * @param AddrWidth specifies if the register address is 8-bit or 16-bit.
 * @param WriteData is a pointer to the data buffer to be written.
 * @param ByteCount is the number of bytes to write from the buffer.
 * @return I2C_AXI_SUCCESS on success, I2C_AXI_NACK_ERROR on NACK, or I2C_AXI_INVALID_PARAM.
 * @note This is a blocking function and will not return until the transaction is complete, fails, or times out.
 */
I2C_AXI_Status I2C_AXI_Master_Write(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *WriteData, u16 ByteCount, u32 TimeoutMs);

/**
 * @brief Perform a blocking (polled) write-then-read exchange on the I2C bus.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param SlaveAddr is the 7-bit address of the target slave device.
 * @param RegAddr is the register address to read from.
 * @param AddrWidth specifies if the register address is 8-bit or 16-bit. 
 * @param ReadData is a pointer to the buffer where read data will be stored.
 * @param ByteCount is the number of bytes to read.
 * @return I2C_AXI_SUCCESS on success, I2C_AXI_NACK_ERROR on NACK, or I2C_AXI_INVALID_PARAM.
 * @note This is a blocking function and will not return until the transaction is complete, fails, or times out.
 */
I2C_AXI_Status I2C_AXI_Master_Exchange(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *ReadData, u16 ByteCount, u32 TimeoutMs);

/**
 * @brief Perform a blocking, interrupt-driven, write-then-read exchange on the I2C bus.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param SlaveAddr is the 7-bit address of the target slave device.
 * @param RegAddr is the register address to read from.
 * @param AddrWidth specifies if the register address is 8-bit or 16-bit.
 * @param ReadData is a pointer to the buffer where read data will be stored.
 * @param ByteCount is the number of bytes to read.
 * @return I2C_AXI_SUCCESS on success, I2C_AXI_NACK_ERROR on NACK, or I2C_AXI_INVALID_PARAM.
 */
I2C_AXI_Status I2C_AXI_Master_Exchange_IT(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *ReadData, u16 ByteCount);

/**
 * @brief Perform a blocking, interrupt-driven, write-then-read exchange on the I2C bus.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param SlaveAddr is the 7-bit address of the target slave device.
 * @param RegAddr is the register address to read from.
 * @param AddrWidth specifies if the register address is 8-bit or 16-bit.
 * @param ReadData is a pointer to the buffer where read data will be stored.
 * @param ByteCount is the number of bytes to read.
 * @return I2C_AXI_SUCCESS on success, I2C_AXI_NACK_ERROR on NACK, or I2C_AXI_INVALID_PARAM.
 */
I2C_AXI_Status I2C_AXI_Master_Exchange_Interrupt(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *ReadData, u16 ByteCount);

/**
 * @brief Perform a blocking (polled) read-only transaction on the I2C bus.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param SlaveAddr is the 7-bit address of the target slave device.
 * @param ReadData is a pointer to the buffer where read data will be stored.
 * @param ByteCount is the number of bytes to read.
 * @return I2C_AXI_SUCCESS on success, I2C_AXI_NACK_ERROR on NACK, or I2C_AXI_TIMEOUT_ERROR.
 * @note This is a blocking function and will not return until the transaction is complete, fails, or times out.
 */
I2C_AXI_Status I2C_AXI_Master_Read(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u8 *ReadData, u16 ByteCount, u32 TimeoutMs);

/**
 * @brief Perform a blocking, interrupt-driven, read-only transaction on the I2C bus.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param SlaveAddr is the 7-bit address of the target slave device.
 * @param ReadData is a pointer to the buffer where read data will be stored.
 * @param ByteCount is the number of bytes to read.
 * @return I2C_AXI_SUCCESS on success, I2C_AXI_NACK_ERROR on NACK.
 */
I2C_AXI_Status I2C_AXI_Master_Read_IT(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u8 *ReadData, u16 ByteCount);

/**
 * @brief Perform a blocking, interrupt-driven, read-only transaction on the I2C bus.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param SlaveAddr is the 7-bit address of the target slave device.
 * @param ReadData is a pointer to the buffer where read data will be stored.
 * @param ByteCount is the number of bytes to read.
 * @return I2C_AXI_SUCCESS on success, I2C_AXI_NACK_ERROR on NACK.
 */
I2C_AXI_Status I2C_AXI_Master_Read_Interrupt(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u8 *ReadData, u16 ByteCount);

/**
 * @brief Perform a non-blocking (interrupt-driven) write to the I2C bus.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param SlaveAddr is the 7-bit address of the target slave device.
 * @param RegAddr is the register address to write to. 
 * @param AddrWidth specifies if the register address is 8-bit or 16-bit.
 * @param WriteData is a pointer to the data buffer to be written.
 * @param ByteCount is the number of bytes to write from the buffer.
 * @return I2C_AXI_SUCCESS on success, I2C_AXI_BUSY if the core is busy, or I2C_AXI_INVALID_PARAM.
 */
I2C_AXI_Status I2C_AXI_Master_Write_IT(I2C_AXI_Master_Driver *InstancePtr, u8 SlaveAddr, u16 RegAddr, I2C_RegAddrWidth AddrWidth, u8 *WriteData, u16 ByteCount);

/**
 * @brief Sets the callback function for handling asynchronous events.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 * @param FuncPtr is the pointer to the callback function.
 * @param CallBackRef is a user-defined pointer to be passed to the callback.
 */
void I2C_AXI_Master_SetHandler(I2C_AXI_Master_Driver *InstancePtr, I2C_AXI_Handler FuncPtr, void *CallBackRef);

/**
 * @brief The Interrupt Service Routine (ISR) for the I2C Master.
 * This function is designed to be connected to the interrupt controller.
 * @param InstancePtr is a pointer to the I2C_AXI_Master_Driver instance.
 */
void I2C_AXI_Master_InterruptHandler(void *InstancePtr);


#endif /* I2C_MASTER_DRIVER_H_ */
