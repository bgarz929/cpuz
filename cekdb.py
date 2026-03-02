import sqlite3
import os

# Nama file database
DB_NAME = "btc_addresses.db"

print("="*50)
print("DIAGNOSA DATABASE BITCOIN")
print("="*50)

# 1. Cek Keberadaan File
path = os.path.abspath(DB_NAME)
print(f"[INFO] Lokasi Script: {os.getcwd()}")
print(f"[INFO] Mencari Database di: {path}")

if not os.path.exists(DB_NAME):
    print("\n[FATAL ERROR] File 'btc_addresses.db' TIDAK DITEMUKAN!")
    print("Pastikan file database ada di folder yang sama dengan script ini.")
    exit()
else:
    print("[OK] File database ditemukan.")

# 2. Cek Koneksi & Tabel
try:
    conn = sqlite3.connect(DB_NAME)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()
    
    # Cek daftar tabel
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table';")
    tables = cursor.fetchall()
    print(f"[INFO] Tabel yang ada di database: {[t[0] for t in tables]}")
    
    if not any(t[0] == 'addresses' for t in tables):
        print("[FATAL ERROR] Tabel 'addresses' tidak ditemukan di dalam database!")
        exit()

    # 3. Cek Nama Kolom (Struktur Asli)
    print("\n[PENTING] STRUKTUR KOLOM ASLI:")
    cursor.execute("SELECT * FROM addresses LIMIT 1")
    columns = [description[0] for description in cursor.description]
    print(columns)
    
    # 4. Cek Sampel Data
    row = cursor.fetchone()
    if row:
        print("\n[INFO] Contoh Data Baris Pertama:")
        for col in columns:
            val = row[col]
            # Potong jika terlalu panjang agar enak dibaca
            val_str = str(val)
            if len(val_str) > 50: val_str = val_str[:50] + "..."
            print(f"  - {col}: {val_str}")
    else:
        print("\n[WARNING] Tabel 'addresses' ditemukan tapi KOSONG (0 data).")

    conn.close()

except Exception as e:
    print(f"\n[ERROR] Terjadi kesalahan saat membaca database:\n{e}")


print("="*50)

