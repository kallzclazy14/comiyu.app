# Comiyu App Hybrid — Flutter source

Versi perbaikan ini mempertahankan UI Bahasa Indonesia dan menyediakan tiga lapisan:

- **LAN:** WebSocket host/client pada Wi-Fi yang sama, tanpa memerlukan Firebase.
- **Online:** Firebase Authentication anonim dan Cloud Firestore.
- **Lokal:** SQLite untuk riwayat dan antrean pesan online yang belum terkirim.

> Status verifikasi: source telah diperbarui dan diperiksa secara statis. Flutter/Dart SDK tidak tersedia di lingkungan pembuatan arsip, sehingga `flutter pub get`, analyzer, tes perangkat, dan build APK/IPA belum dapat dijalankan. Arsip berisi source Flutter, bukan APK siap instalasi.

## 1. Persiapan Flutter

Jika folder platform belum ada, dari direktori proyek jalankan:

```bash
flutter create .
flutter pub get
```

Gunakan Flutter stable dan Android Studio/Android SDK untuk Android. Build iOS memerlukan macOS dan Xcode.

## 2. Firebase (hanya untuk mode online)

1. Buat proyek di [Firebase Console](https://console.firebase.google.com/).
2. Tambahkan aplikasi Android/iOS dengan application ID dan bundle ID yang sesuai.
3. Aktifkan **Authentication → Sign-in method → Anonymous**.
4. Buat database **Cloud Firestore**.
5. Pasang FlutterFire CLI dan jalankan:

```bash
dart pub global activate flutterfire_cli
flutterfire configure
```

Perintah itu akan mengganti `lib/firebase_options.dart` placeholder dengan konfigurasi platform yang benar. Android/iOS native config juga harus ditambahkan sesuai output FlutterFire.
6. Salin isi `firestore.rules` ke **Firestore → Rules**, lalu publikasikan.

Tanpa konfigurasi Firebase, aplikasi tetap dapat membuka profil lokal dan mode LAN; fitur pencarian nomor dan pesan internet tidak tersedia. Autentikasi anonim mengikat akun ke instalasi aplikasi. Tambahkan mekanisme pemulihan akun sebelum rilis publik.

## 3. Izin platform

### Android

Salin permission pada `android_manifest_permissions.xml` ke dalam elemen `<manifest>` di `android/app/src/main/AndroidManifest.xml`.

Untuk pengujian LAN, WebSocket memakai `ws://` (tanpa TLS). Jika Android menolak cleartext pada build debug, aktifkan `android:usesCleartextTraffic="true"` pada elemen `<application>` khusus konfigurasi debug. Jangan mengaktifkannya untuk rilis produksi; gunakan WSS/TLS atau kanal lokal terenkripsi.

### iOS

Tambahkan ke `ios/Runner/Info.plist`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Comiyu menggunakan jaringan lokal untuk mengirim pesan ke perangkat lain pada Wi-Fi yang sama.</string>
```

Karena alamat host dimasukkan manual, Bonjour service declaration tidak diperlukan. Uji prompt Local Network pada perangkat fisik. Build iOS membutuhkan macOS/Xcode.

## 4. Menjalankan

```bash
flutter pub get
flutter run
```

## 5. Alur LAN dua perangkat

1. Sambungkan dua perangkat ke Wi-Fi yang sama. Router tidak boleh mengaktifkan client/AP isolation.
2. Di perangkat host pilih **Pesan melalui jaringan lokal → Jadikan perangkat ini host**.
3. Bagikan IP dan port `4040` yang ditampilkan.
4. Di perangkat klien masukkan IP host lalu pilih **Gabung ke host**.
5. Host membuat `roomId` acak dan mengirimkannya ke klien lewat paket `hello`; kedua sisi menggunakan ID ruang yang sama.
6. Pesan klien diterima host lalu disiarkan ke seluruh peer, termasuk pengirim. Pesan host juga disiarkan ke semua klien.
7. Tiap pesan membawa UUID yang sama. SQLite memakai ID sebagai primary key dan mengabaikan insert duplikat; layar juga memeriksa ID sebelum menambah pesan.

Host harus tetap menjalankan aplikasi dan berada pada layar/aktivitas yang tidak dihentikan sistem. Implementasi ini belum memiliki penemuan host otomatis, autentikasi peer, enkripsi, atau pemulihan koneksi otomatis.

## 6. Antrean dan sinkronisasi online

- Pesan online ditulis dahulu ke SQLite dan tabel `pending_messages` sebelum dicoba dikirim.
- Jika internet putus, antrean tetap ada setelah aplikasi ditutup/dibuka.
- Saat konektivitas kembali, antrean dikirim berurutan.
- ID lokal digunakan sebagai ID dokumen Firestore. Jika respons jaringan hilang setelah server menerima pesan, retry menulis dokumen dengan ID yang sama, bukan membuat pesan baru.
- Antrean dihapus hanya setelah operasi Firestore selesai; kegagalan menaikkan penghitung percobaan dan menghentikan batch sementara.

Sinkronisasi ini berlaku untuk **pesan online yang tertunda**, bukan pengunggahan otomatis pesan LAN ke cloud. Riwayat LAN tetap lokal di masing-masing perangkat.

## 7. Aturan keamanan dan batasan

`firestore.rules` membatasi profil ke pemilik UID, mencegah pengambilalihan nomor yang telah terdaftar, membatasi percakapan ke anggota, memvalidasi isi pesan, dan mengizinkan retry dokumen pesan hanya bila datanya identik. Tetap lakukan audit keamanan sebelum produksi.

Batasan yang masih ada:

- Nomor Pengguna acak belum memiliki reservasi server yang benar-benar atomik saat dua perangkat membuat nomor sama pada waktu bersamaan; kegagalan konflik perlu ditangani dengan membuat nomor baru.
- Auth anonim tidak menyediakan pemulihan akun lintas instalasi.
- Foto profil hanya tersimpan lokal; belum diunggah ke Firebase Storage.
- LAN masih memakai WebSocket tanpa TLS dan tanpa autentikasi peer. Gunakan hanya pada jaringan tepercaya untuk pengujian.
- LAN membutuhkan IP manual, host harus aktif, dan tidak ada store-and-forward ketika peer terputus.
- Antrean offline hanya untuk pesan online yang dibuat dari percakapan yang sudah diketahui; pencarian kontak baru tetap memerlukan internet.
- Pesan LAN tidak otomatis disinkronkan ke Firestore ketika internet kembali.
- Belum ada enkripsi end-to-end, rate limiting, moderasi spam, atau audit produksi.

## Struktur utama

- `lib/main.dart` — UI, state, dan antrean sinkronisasi.
- `lib/services/lan_service.dart` — server/klien WebSocket dan room handshake.
- `lib/services/local_store.dart` — SQLite, deduplikasi, antrean.
- `lib/services/firebase_chat_service.dart` — Auth anonim, direktori, dan Firestore.
- `lib/firebase_options.dart` — placeholder yang diganti `flutterfire configure`.
- `firestore.rules` — aturan akses Firestore.

## 8. Membuat APK otomatis melalui GitHub Actions

Arsip ini menyertakan workflow `.github/workflows/android-apk.yml` untuk membangun **APK debug** di GitHub Actions. Workflow membuat folder Android dengan `flutter create`, menambahkan izin jaringan, menjalankan `flutter pub get`, lalu menghasilkan `app-debug.apk`.

1. Ekstrak ZIP dan buat repository baru di GitHub (misalnya `comiyu-app`).
2. Unggah seluruh isi folder `comiyu_hybrid` ke repository tersebut, termasuk folder tersembunyi `.github`.
3. Buka tab **Actions** dan izinkan workflow berjalan jika GitHub memintanya.
4. Jalankan workflow **Build Comiyu Android APK** melalui tombol **Run workflow**, atau lakukan push ke branch `main`/`master`.
5. Setelah status workflow hijau, buka detail run dan unduh artifact **comiyu-debug-apk**. Ekstrak artifact untuk memperoleh `app-debug.apk`.
6. Pindahkan APK ke Android dan izinkan pemasangan aplikasi dari sumber tersebut bila diminta.

Workflow menghasilkan APK debug untuk pengujian, bukan rilis Play Store. Konfigurasi Firebase belum disediakan; aplikasi akan mencoba berjalan tanpa Firebase sehingga pengujian lokal/LAN dapat dilakukan. Fitur online Firebase memerlukan konfigurasi FlutterFire tersendiri. Cleartext WebSocket hanya diaktifkan pada manifest debug untuk pengujian LAN.
