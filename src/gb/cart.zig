//! The cartridge: ROM banking, and battery RAM.
//!
//! Metroid II's header declares `$03` at `$0147` - MBC1 with RAM and a battery
//! - `$03` at `$0148` (256 KiB, 16 banks) and `$02` at `$0149` (8 KiB of RAM).
//! blargg's combined `cpu_instrs.gb` is also MBC1, at 64 KiB, which is why the
//! test suite exercises banking at all: the eleven individual ROMs are 32 KiB
//! and never switch a bank.
//!
//! Only MBC1 and plain 32 KiB carts are implemented, and an unknown mapper is
//! refused rather than approximated. Guessing would produce a machine that
//! runs the wrong bytes and reports success.

const std = @import("std");

pub const Mapper = enum { rom_only, mbc1 };

pub const Error = error{ UnsupportedMapper, BadRomSize };

pub const bank_size: usize = 0x4000;
pub const ram_bank_size: usize = 0x2000;

pub const Cart = struct {
    rom: []const u8,
    mapper: Mapper,
    /// External RAM. Owned by the caller, so a save file can be handed in.
    ram: []u8,

    /// The 5-bit register at $2000-$3FFF. Held unmasked: the "bank 0 becomes
    /// bank 1" rule applies to the *written* value, before the high bits are
    /// mixed in, which is why it cannot be pre-masked.
    rom_bank_lo: u5 = 1,
    /// The 2-bit register at $4000-$5FFF: ROM bank high bits in mode 0, RAM
    /// bank select in mode 1.
    bank_hi: u2 = 0,
    /// $6000-$7FFF. False = mode 0 (ROM banking), true = mode 1 (RAM banking).
    mode1: bool = false,
    ram_enabled: bool = false,

    pub fn init(rom: []const u8, ram: []u8) Error!Cart {
        if (rom.len < 0x150 or rom.len % bank_size != 0) return Error.BadRomSize;
        const mapper: Mapper = switch (rom[0x0147]) {
            0x00 => .rom_only,
            0x01, 0x02, 0x03 => .mbc1,
            else => return Error.UnsupportedMapper,
        };
        return .{ .rom = rom, .mapper = mapper, .ram = ram };
    }

    pub fn banks(self: Cart) usize {
        return self.rom.len / bank_size;
    }

    /// The bank mapped at $4000-$7FFF.
    pub fn highBank(self: Cart) usize {
        if (self.mapper == .rom_only) return 1;
        const lo: usize = if (self.rom_bank_lo == 0) 1 else self.rom_bank_lo;
        const hi: usize = if (self.mode1) 0 else @as(usize, self.bank_hi) << 5;
        return (hi | lo) % self.banks();
    }

    /// The bank mapped at $0000-$3FFF. Normally 0; in MBC1 mode 1 on a cart
    /// large enough to use them, the high bits apply here too.
    pub fn lowBank(self: Cart) usize {
        if (self.mapper == .rom_only or !self.mode1) return 0;
        return (@as(usize, self.bank_hi) << 5) % self.banks();
    }

    fn ramBank(self: Cart) usize {
        if (self.ram.len <= ram_bank_size) return 0;
        const b: usize = if (self.mode1) self.bank_hi else 0;
        return b % (self.ram.len / ram_bank_size);
    }

    pub fn read(self: *const Cart, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x3FFF => self.rom[self.lowBank() * bank_size + addr],
            0x4000...0x7FFF => self.rom[self.highBank() * bank_size + (addr - 0x4000)],
            0xA000...0xBFFF => blk: {
                if (!self.ram_enabled or self.ram.len == 0) break :blk 0xFF;
                const off = self.ramBank() * ram_bank_size + (addr - 0xA000);
                break :blk if (off < self.ram.len) self.ram[off] else 0xFF;
            },
            else => 0xFF,
        };
    }

    pub fn write(self: *Cart, addr: u16, v: u8) void {
        switch (addr) {
            0x0000...0x1FFF => self.ram_enabled = (v & 0x0F) == 0x0A,
            0x2000...0x3FFF => self.rom_bank_lo = @truncate(v),
            0x4000...0x5FFF => self.bank_hi = @truncate(v),
            0x6000...0x7FFF => self.mode1 = (v & 1) != 0,
            0xA000...0xBFFF => {
                if (!self.ram_enabled or self.ram.len == 0) return;
                const off = self.ramBank() * ram_bank_size + (addr - 0xA000);
                if (off < self.ram.len) self.ram[off] = v;
            },
            else => {},
        }
    }
};

// ---- Tests ----------------------------------------------------------------

const testing = std.testing;

fn fakeRom(allocator: std.mem.Allocator, bank_count: usize, cart_type: u8) ![]u8 {
    const rom = try allocator.alloc(u8, bank_count * bank_size);
    @memset(rom, 0);
    rom[0x0147] = cart_type;
    // Stamp each bank with its own number so a read proves which bank is live.
    for (0..bank_count) |b| rom[b * bank_size] = @intCast(b);
    return rom;
}

test "writing 0 to the bank register selects bank 1, not bank 0" {
    const gpa = testing.allocator;
    const rom = try fakeRom(gpa, 16, 0x03);
    defer gpa.free(rom);
    var ram: [0x2000]u8 = @splat(0);
    var cart = try Cart.init(rom, &ram);

    cart.write(0x2000, 0);
    try testing.expectEqual(@as(usize, 1), cart.highBank());
    try testing.expectEqual(@as(u8, 1), cart.read(0x4000));

    cart.write(0x2000, 5);
    try testing.expectEqual(@as(u8, 5), cart.read(0x4000));
    // $0000-$3FFF stays on bank 0 in mode 0.
    try testing.expectEqual(@as(u8, 0), cart.read(0x0000));
}

test "the bank number wraps within the cart rather than reading past it" {
    const gpa = testing.allocator;
    const rom = try fakeRom(gpa, 4, 0x01); // 64 KiB, like cpu_instrs.gb
    defer gpa.free(rom);
    var cart = try Cart.init(rom, &.{});
    cart.write(0x2000, 7); // beyond the 4 banks present
    try testing.expectEqual(@as(usize, 3), cart.highBank());
    try testing.expectEqual(@as(u8, 3), cart.read(0x4000));
}

test "mode 1 moves the high bits to the low bank and the RAM bank" {
    const gpa = testing.allocator;
    const rom = try fakeRom(gpa, 64, 0x03); // 1 MiB: big enough for the high bits to matter
    defer gpa.free(rom);
    var ram: [0x8000]u8 = @splat(0);
    var cart = try Cart.init(rom, &ram);

    cart.write(0x4000, 1); // high bits = 1
    cart.write(0x2000, 1);
    try testing.expectEqual(@as(usize, 0x21), cart.highBank());
    try testing.expectEqual(@as(usize, 0), cart.lowBank());

    cart.write(0x6000, 1); // mode 1
    try testing.expectEqual(@as(usize, 0x20), cart.lowBank());
    try testing.expectEqual(@as(usize, 1), cart.highBank()); // high bits left the ROM bank
}

test "external RAM ignores reads and writes until it is enabled" {
    const gpa = testing.allocator;
    const rom = try fakeRom(gpa, 16, 0x03);
    defer gpa.free(rom);
    var ram: [0x2000]u8 = @splat(0);
    var cart = try Cart.init(rom, &ram);

    cart.write(0xA000, 0x42);
    try testing.expectEqual(@as(u8, 0xFF), cart.read(0xA000));
    try testing.expectEqual(@as(u8, 0), ram[0]);

    cart.write(0x0000, 0x0A);
    cart.write(0xA000, 0x42);
    try testing.expectEqual(@as(u8, 0x42), cart.read(0xA000));

    // Any value whose low nibble is not $A disables it again.
    cart.write(0x0000, 0x00);
    try testing.expectEqual(@as(u8, 0xFF), cart.read(0xA000));
}

test "an unknown mapper is refused rather than approximated" {
    const gpa = testing.allocator;
    const rom = try fakeRom(gpa, 16, 0x19); // MBC5
    defer gpa.free(rom);
    try testing.expectError(Error.UnsupportedMapper, Cart.init(rom, &.{}));

    const short = try gpa.alloc(u8, 0x100);
    defer gpa.free(short);
    try testing.expectError(Error.BadRomSize, Cart.init(short, &.{}));
}
