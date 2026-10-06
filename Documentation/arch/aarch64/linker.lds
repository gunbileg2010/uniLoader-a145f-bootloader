ENTRY(
      _head
     );
OUTPUT_FORMAT("elf64-littleaarch64")
OUTPUT_ARCH(aarch64)
TARGET(binary)
INPUT(blob/Image)
INPUT(blob/dtb)
INPUT(blob/ramdisk)
SECTIONS
{
 . = 0xa0000000;
 .text : {
  _reloc_start = .;
  *(.text)
  *(.text.*)
 }
 .kernel ALIGN(4096) : {
  kernel = .;
  blob/Image
 }
 .dtb ALIGN(4096) : {
  dtb = .;
  blob/dtb
 }
 .ramdisk ALIGN(4096) : {
  ramdisk = .;
  blob/ramdisk
 }
 .rodata ALIGN(8) : {
  *(.rodata)
  *(.rodata.*)
 }
 .uniloader_drivers ALIGN(8) : {
  __drivers_start = .;
  KEEP(*(.uniloader_drivers))
  __drivers_end = .;
 }
 .data ALIGN(8) : {
  *(.data)
  *(.data.*)
 }
 .bss ALIGN(8) : {
  __bss_start = .;
  *(.bss)
  *(.bss.*)
  *(COMMON)
  . = ALIGN(8);
  __bss_end = .;
 }
 .stack ALIGN(4096) : {
  . = . + 4096;
  _stack_end = .;
  _reloc_end = .;
 }
 kernel_size = SIZEOF(.kernel);
 ramdisk_size = SIZEOF(.ramdisk);
 _reloc_size = _reloc_end - _reloc_start;
 _kernel_size = _stack_end - _start;
 /DISCARD/ : {
  *(.eh_frame)
  *(.eh_frame.*)
  *(.note.gnu.property)
  *(.note.gnu.build-id)
  *(.comment)
  *(.ARM.attributes)
 }
}
