# Rancangan Sistem ERP — Arsitektur Database & Metode Akuntansi

## Dasar Pemikiran

Sistem ini dirancang dengan menggabungkan dua pendekatan: arsitektur database modular khas ERP dan metode double-entry accounting yang diadopsi dari TigerBeetle. Fokus utamanya adalah akurasi data akuntansi, audit trail yang lengkap, dan pemisahan data operasional dari data finansial.

Metode flag dan pending transfer dari TigerBeetle menjadi inspirasi utama untuk menangani transaksi yang membutuhkan validasi sebelum di-posting ke buku besar.

---

## Arsitektur 4 Database

Database dipisahkan berdasarkan siklus hidup data. Ada yang permanen (seumur hidup sistem) dan ada yang periodik (per tahun fiskal).

```
┌──────────────────────────────────────────────────────────────┐
│ ERP — Elixir/Phoenix                                         │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  DB 1: Master (permanen)                                      │
│  ─────────────────────────                                     │
│  products, categories, customers, vendors,                     │
│  warehouses, tax rates, exchange rates,                        │
│  users & permissions, chart of account (COA)                   │
│                                                               │
│  DB 2: Accounting (permanen)                                   │
│  ──────────────────────────                                    │
│  Account balances — debit/credit model TigerBeetle             │
│  ├── debits_pending, debits_posted                             │
│  ├── credits_pending, credits_posted                           │
│  └── Terus update. Closing balance tahun ini =                 │
│       opening balance tahun depan                              │
│                                                               │
│  DB 3: Journal (per tahun fiskal)                              │
│  ──────────────────────────────                                │
│  Journal entry header + lines                                  │
│  ├── debit_account_id, credit_account_id, amount               │
│  ├── reference ke PO / GRN / Invoice                           │
│  └── Status: pending / posted / voided                         │
│                                                               │
│  DB 4: Subsidiary Ledger (per tahun fiskal)                    │
│  ────────────────────────────────────────                      │
│  Purchase Order, GRN, Sales Order, Invoice,                    │
│  Payment, Stock Movement                                       │
│  ├── Masing-masing punya status                                │
│  └── Status: draft / confirmed / posted / closed               │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### Alasan Pemisahan

**DB Master — Permanen:**
Data referensi gak berubah banyak. Product, customer, chart of account — sekali dibuat, dipakai terus. Gak perlu di-archive.

**DB Accounting — Permanen:**
Saldo akun harus terus bisa diakses kapan pun. Laporan laba rugi 3 tahun lalu? Neraca 5 tahun lalu? Tinggal query tanpa restore old database.

**DB Journal — Per Tahun Fiskal:**
Journal entries tumbuh cepat. Pemisah per tahun bikin performa query stabil, backup lebih kecil, dan tutup buku jadi lebih bersih.

**DB Subsidiary Ledger — Per Tahun Fiskal:**
Detail transaksi operasional (PO, GRN, Invoice, stock movement) paling besar volumenya. Setelah tutup buku, database tahun sebelumnya bisa di-archive atau di-read-only.

---

## Metode Akuntansi — Flags & Pending (dari TigerBeetle)

TigerBeetle menggunakan konsep pending/post/void untuk menangani two-phase transfer. Konsep ini diadaptasi ke ERP untuk menangani transaksi yang barangnya sudah bergerak tetapi pencatatan jurnalnya belum final.

### Mapping TigerBeetle → ERP

| TigerBeetle | ERP — Journal Entry | Fungsi |
|-------------|:-------------------:|--------|
| `flags.pending` | `status = pending` | Transaksi tercatat, tapi belum final |
| `flags.post_pending_transfer` | `status = posted` | Setelah audit/verifikasi |
| `flags.void_pending_transfer` | `status = voided` | Journal di-reverse |
| `flags.linked` | Chain dalam batch transaksi | Atomic: all or nothing |
| `exceeds_credits` | Balance check negatif | Trigger audit trail |

### Account Balance Model

Setiap akun punya 4 field balance — persis kayak TigerBeetle:

```
Account.account_balances:
  debits_pending   → total debit yang belum di-post
  debits_posted    → total debit yang sudah final
  credits_pending  → total credit yang belum di-post
  credits_posted   → total credit yang sudah final

Saldo real-time = credits_posted - debits_posted
```

Kenapa pakai pending? Untuk transaksi yang masuk audit trail. Journal entry tercatat (pending) tapi balance belum di-update sampai supervisor approve.

---

## Flow Transaksi — POS Swalayan

Ini contoh konkret: penjualan di swalayan. Barang sudah di-scan dan dipegang customer. Gak ada opsi cancel di tingkat barang — barang fisik sudah keluar.

### Step-by-step

```
1. SCAN BARANG DI KASIR
   ├── Stock quantity_posted -= qty
   │   (barang keluar — final. Gak bisa balik.)
   ├── Kalo stok minus? TETAP KELUAR.
   │   Stock minus bukan penghalang — barang udah di customer.
   └── Catat di Subsidiary Ledger: sales_order status = confirmed

2. GENERATE JOURNAL ENTRY
   ├── Debit: Kas / Piutang
   ├── Credit: Penjualan
   └── Status: PENDING
       (ini yang pending — pencatatan jurnalnya, bukan barangnya)

3. CEK SALDO — NEGATIVE STOCK ALERT
   ├── Kalo product stock < 0:
   ├── INSERT ke audit trail:
   │   "Produk XXX: stock -2 unit. Sales Order #SO-2026-00123"
   │   "Tanggal: 2026-07-24 14:30. Kasir: Budi"
   └── Flag audit_required = true

4. TUGAS SUPERVISOR
   ├── Buka audit trail
   ├── Lihat: "Produk XXX minus 2 unit"
   ├── Investigasi — cek fisik, cek histori
   │   Mungkin: sistem salah catat penerimaan barang.
   │   Atau: barang digondol, atau salah scan.
   └── Lakukan stock opname adjustment

5. STOCK OPNAME
   ├── Cek fisik: stock seharusnya 10, sistem bilang -2
   ├── Adjustment: +12 unit
   ├── Journal entry:
   │   Debit: Persediaan
   │   Credit: Selisih Stock Opname
   └── Journal status → POSTED
```

### Diagram Status

```
  ┌──────────┐     ┌──────────┐     ┌──────────┐
  │ BARANG   │────►│ JOURNAL  │────►│ JOURNAL  │
  │ KELUAR   │     │ PENDING  │     │ POSTED   │
  │ (final)  │     │          │     │          │
  └──────────┘     └──────────┘     └──────────┘
                        │
                   ┌────┴────┐
                   │         │
                   ▼         ▼
            ┌──────────┐  ┌──────────┐
            │ AUDIT    │  │ STOCK    │
            │ TRAIL    │  │ OPDATE   │
            └──────────┘  └──────────┘
```

---

## Flow Pembelian (Purchase-to-Pay)

```
1. Purchase Order (Subsidiary Ledger)
   ├── Status: draft → confirmed
   └── Belum ada impact ke accounting

2. GRN — Goods Receipt Note
   ├── Barang masuk → stock quantity_posted += qty
   ├── Status PO: partially_received / fully_received
   └── Belum ada journal entry (masih hutang ke vendor)

3. Invoice
   ├── Vendor kirim tagihan
   ├── Match dengan PO + GRN (3-way matching)
   │   quantity match? price match?
   ├── Kalo cocok → approve
   └── Generate journal entry:
       Debit: Persediaan (atau Biaya)
       Credit: Hutang Dagang
       Status: pending

4. Payment
   ├── Bayar ke vendor
   ├── Journal entry:
       Debit: Hutang Dagang
       Credit: Kas / Bank
       Status: pending

5. Audit / Tutup Periode
   ├── Supervisor review journal entries pending
   ├── Validasi: invoice match? payment correct?
   └── Journal status → posted

Pendekatan PENDING di sini: invoice approval masih pending
sampai supervisor yakin 3-way match benar. Tapi hutang
sudah tercatat di balance (pending).
```

---

## Struktur Data — Account Balance

```sql
-- Ini model yang diadopsi dari TigerBeetle Account
CREATE TABLE account_balances (
    id              INTEGER PRIMARY KEY,

    -- Chart of account reference
    account_id      INTEGER NOT NULL REFERENCES accounts(id),
    fiscal_year     INTEGER NOT NULL,  -- 2026

    -- Balance — model TigerBeetle (128-bit decimal)
    debits_pending  DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    debits_posted   DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    credits_pending DECIMAL(18,2) NOT NULL DEFAULT 0.00,
    credits_posted  DECIMAL(18,2) NOT NULL DEFAULT 0.00,

    -- Tracking
    last_journal_id INTEGER,
    last_entry_date DATE,

    UNIQUE(account_id, fiscal_year)
);
```

### Revenue Account — Selisih

Perhatikan: revenue account balance di TigerBeetle tidak memiliki selisih. Dalam model double-entry, revenue selalu di sisi credit:

```
Revenue account:
  credits_posted - debits_posted = saldo revenue

Asset account:
  debits_posted - credits_posted = saldo asset
```

Untuk selisih (gain/loss) — ini yang lo maksud:

```
Selisih terjadi ketika:
1. Transaksi valas: rate berbeda waktu beli vs waktu bayar
2. Stock opname: stock fisik berbeda dengan sistem
3. Adjustment: kesalahan pencatatan

Treatment:
├── Selisih valas → masuk akun "Laba/Rugi Selisih Kurs"
├── Stock opname → masuk akun "Selisih Persediaan"
└── Adjustment lain → masuk akun "Penyesuaian"
```

---

## Stock Movement — Flags Implementation

```elixir
defmodule Erp.Inventory do
  @flag_pending      0b0001  # barang di-reserve
  @flag_posted       0b0010  # barang keluar final
  @flag_voided       0b0100  # movement dibatalkan
  @flag_linked       0b1000  # chain dengan transaksi lain

  defstruct [
    :id, :product_id, :warehouse_id, :quantity,
    :status,              # pending | posted | voided
    :reference_type,      # "sales_order" | "purchase_receipt" | "adjustment"
    :reference_id,
    :flags,               # bitmask 16-bit
    :notes
  ]
end
```

---

## Audit Trail Mechanism

Audit trail bukan sekadar log. Ini mekanisme yang napsu transaksi untuk di-review:

```elixir
defmodule Erp.AuditTrail do
  schema "audit_trails" do
    field :event_type,    :string  # "negative_stock" | "price_mismatch" | "journal_pending"
    field :severity,      :string  # "info" | "warning" | "critical"
    field :status,        :string  # "open" | "investigating" | "resolved"

    # Reference
    field :reference_type, :string # "sales_order" | "journal_entry" | "product"
    field :reference_id,  :id

    # Data
    field :description,   :string
    field :details,       :map     # JSON — data lengkap

    # Resolution
    field :resolved_by,   :id
    field :resolved_at,   :utc_datetime
    field :resolution,    :string  # "adjusted" | "accepted" | "voided"

    timestamps()
  end
end
```

### Trigger Points

| Event | Trigger | Severity |
|-------|---------|----------|
| Stock minus setelah penjualan | `if balance < 0` | warning |
| Invoice amount != PO amount | `if invoice.total != po.total` | warning |
| Payment > invoice | `if payment.amount > invoice.balance_due` | info |
| Journal pending > 7 hari | `if pending.created_at < 7.days.ago()` | warning |
| Stock opname selisih besar | `if abs(adjustment) > threshold` | critical |

---

## Tutup Buku — Akhir Tahun Fiskal

```
1. HOLD semua transaksi baru
2. Generate closing entries:
   ├── Tutup revenue & expense ke retained earnings
   └── Post semua journal pending → final
3. Final balance → opening balance tahun depan
4. Archive database tahun berjalan:
   ├── DB Journal 2026 → read-only
   └── DB Subsidiary 2026 → read-only
5. Buka database baru:
   ├── DB Journal 2027 (baru, kosong)
   └── DB Subsidiary 2027 (baru, kosong)
6. DB Accounting tetap update — balance 2027
   mulai dari opening balance 2026 final
```

---

## Teknologi & Stack

| Layer | Teknologi | Alasan |
|-------|-----------|--------|
| App server | Elixir/Phoenix | Fault tolerance BEAM, concurrency, hot reload |
| ORM | Ecto | Mature, support SQLite + PostgreSQL |
| DB engine | SQLite (WAL mode) | Zero konfigurasi, embedded, sub-millisecond read |
| Backup | Litestream | WAL streaming ke S3, point-in-time recovery < 30 detik |
| OS | FreeBSD 15 | ZFS, jail, performa network stabil |

SQLite WAL mode — konfigurasi production:

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=NORMAL;
PRAGMA cache_size=-64000;     -- 64 MB cache
PRAGMA mmap_size=268435456;   -- 256 MB memory-mapped I/O
PRAGMA foreign_keys=ON;
```

---

## Konsep Flags TigerBeetle untuk Journal Entry

Bitmask 16-bit untuk field `flags` di journal entry:

| Bit | Name | Fungsi |
|:---:|------|--------|
| 0 | `linked` | Chain entry dalam satu batch — atomic |
| 1 | `pending` | Entry belum final, balance pending |
| 2 | `post_pending` | Finalisasi — posted. Balance pindah ke posted |
| 3 | `void_pending` | Reverse entry. Kembalikan balance |
| 4 | `imported` | Import data historical dari sistem lama |
| 5 | `reversal` | Entry ini adalah reversal dari entry sebelumnya |
| 6 | `audit_required` | Flag otomatis — perlu review supervisor |

Contoh penggunaan flag di flow:

```elixir
# POS sale — barang keluar, journal pending
Journal.create_entry(%{
  debit_account_id: kas,
  credit_account_id: penjualan,
  amount: 150_000,
  flags: @flag_linked | @flag_pending
})

# Supervisor approve — post journal
Journal.post_entry(entry_id)
# Status → posted
# flags: @flag_linked | @flag_post_pending

# Supervisor tolak — void journal
Journal.void_entry(entry_id)
# Status → voided
# flags: @flag_linked | @flag_void_pending
# Generate reversing entry otomatis
```

---

## Referensi

- TigerBeetle documentation: https://docs.tigerbeetle.com
- TigerBeetle FreeBSD port: https://github.com/a3pelawi/tigerbeetle/tree/port-freebsd (branch port-freebsd)
- SQLite WAL mode: https://www.sqlite.org/wal.html
- Litestream: https://litestream.io
