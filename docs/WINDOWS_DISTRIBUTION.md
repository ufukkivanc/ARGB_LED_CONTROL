# Windows Dağıtımı (ARGB Controller)

Flutter SDK, VS Code veya terminal kullanmadan Windows 10/11 üzerinde kurulup çalıştırılabilen tek dosyalık kurulum paketi.

> **Durum:** Kurulum paketi `scripts\build-windows-installer.ps1` ile üretildi ve bu makinede **sessiz kurulum / güncelleme / kaldırma / yeniden kurulum**
> senaryolarıyla denendi (35 doğrulama). **Temiz bir başka bilgisayarda** (özellikle VC++ çalışma zamanı kurulu olmayan) ve **kod imzalı** olarak denenmedi.

## Kullanıcı için

1. `ARGBController-Setup-<sürüm>.exe` dosyasını çalıştırın (yönetici hakkı gerekmez; kullanıcı bazlı kurulur: `%LOCALAPPDATA%\Programs\ARGB Controller`).
   Sihirbazın ilk sayfasında "tüm kullanıcılar için kur" seçilirse yönetici onayı istenir.
2. İsteğe bağlı **masaüstü kısayolu** işaretlenebilir; **Başlat menüsü** kısayolu her zaman oluşturulur.
3. Kaldırmak için: *Ayarlar ▸ Uygulamalar ▸ Yüklü uygulamalar ▸ ARGB Controller ▸ Kaldır* (veya Denetim Masası ▸ Program Ekle/Kaldır).
4. **Güncelleme:** yeni sürümün kurulum dosyasını çalıştırmanız yeterlidir; eski sürümün üzerine kurulur, ayarlarınız ve eşleştirmeleriniz korunur.

### SmartScreen uyarısı

Kurulum dosyası **kod imzalı değildir**. Windows SmartScreen ilk çalıştırmada *"Windows bilgisayarınızı korudu / Bilinmeyen yayıncı"* uyarısı gösterebilir:
**Ek bilgi ▸ Yine de çalıştır** ile devam edilir. Bu, dosyanın zararlı olduğu anlamına gelmez; yalnızca yayıncının Microsoft tarafından doğrulanmış bir sertifikayla
imzalanmadığını ve dosyanın henüz yeterli "itibar" kazanmadığını gösterir. Dosyanın bütünlüğünü, yayınla birlikte verilen `.sha256` dosyasıyla doğrulayabilirsiniz:

```powershell
(Get-FileHash .\ARGBController-Setup-0.3.1.exe -Algorithm SHA256).Hash
```

**Kod imzalama gereksinimi (kaldırmak için):** SmartScreen'in uyarısı yalnızca bir **kod imzalama sertifikası** ile imzalama (ve zamanla itibar birikimi) sonrasında kalkar.
Seçenekler: OV (Organization Validation) sertifika (uyarı itibar birikince azalır), EV (Extended Validation) sertifika (itibar hemen verilir, donanım anahtarı gerekir),
veya Azure Trusted Signing. Sertifika elde edildiğinde betik doğrudan imzalar:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-windows-installer.ps1 -SignCertThumbprint <SHA1_PARMAK_IZI> [-SignToolPath "C:\...\signtool.exe"]
```

(Bu imzalama yolu henüz gerçek bir sertifikayla denenmedi.)

## Geliştirici için: kurulum paketini üretme

Gereksinimler: Flutter SDK (Windows desktop açık), Visual Studio "Desktop development with C++" (derleyici + VC++ DLL'leri), **Inno Setup 6**
(`winget install JRSoftware.InnoSetup`), Windows'ta Geliştirici Modu.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\build-windows-installer.ps1               # analiz + test + release + kurulum paketi
powershell -ExecutionPolicy Bypass -File scripts\build-windows-installer.ps1 -SkipTests -SkipAnalyze   # hızlı yeniden paketleme
```

Çıktı: `dist\ARGBController-Setup-<sürüm>.exe` ve `.sha256` (klasör `.gitignore`'dadır). Sürüm `argb_controller_app\pubspec.yaml` içindeki `version: x.y.z+n` değerinden gelir
(Windows exe'sinin dosya/ürün sürümü de buradan üretilir). Betik adımları: ön kontroller → `flutter pub get` → `flutter analyze` → `flutter test` → `flutter build windows --release`
→ `dist\stage` hazırlama (Release çıktısı + VC++ DLL'leri) → Inno Setup.

**ASCII olmayan klasör yolu:** Proje yolunda `Ç` gibi karakterler varsa Flutter/MSBuild Release derlemesi başarısız olur. Betik bunu algılar ve projeyi geçici bir sürücü harfi
(`subst Z:`) altında derler; elle `flutter build windows` çalıştırıyorsanız projeyi ASCII bir klasöre taşıyın.

### Paket içeriği

`ARGBController.exe`, `flutter_windows.dll`, eklenti DLL'leri (`serialport.dll`, `flutter_libserialport_plugin.dll`, `flutter_secure_storage_windows_plugin.dll`, `nsd_windows_plugin.dll`),
`data\` (Flutter varlıkları, AOT kodu, ICU) ve VC++ çalışma zamanı DLL'leri. Kurulum dosyası ≈ 11 MB, kurulu boyut ≈ 30 MB.

### Visual C++ çalışma zamanı

Flutter Windows uygulamaları Microsoft VC++ çalışma zamanına bağlıdır. `dumpbin /dependents` ile doğrulanan gereksinim: **`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`**
(UCRT `api-ms-win-crt-*` Windows 10/11 ile gelir). Bu üç DLL **uygulama klasörüne konur** (uygulama-yerel dağıtım; Visual Studio'nun redistributable dosyalarından,
Microsoft'un dağıtım koşullarına uygun olarak), böylece son kullanıcının ayrıca "Visual C++ Redistributable" kurması gerekmez. Betik bu DLL'leri Visual Studio'nun
`VC\Redist\MSVC\<sürüm>\x64\Microsoft.VC*.CRT` klasöründen alır (`-CrtDir` ile değiştirilebilir). Alternatif: Microsoft'un `vc_redist.x64.exe` dosyasını ayrıca dağıtmak.

### Kullanıcı ayarları (güncelleme ve yeniden kurulumda korunur)

Ayarlar (mod, bilinen cihazlar) ve eşleştirme token'ları kurulum klasörünün **dışında** tutulur:
`%APPDATA%\ARGB LED Control\ARGB Controller\` (`shared_preferences.json`, güvenli depolama dosyası). Klasör adı, exe'nin sürüm kaynağındaki
*CompanyName* + *ProductName* değerlerinden gelir (`windows\runner\Runner.rc`) — **bu iki değer değişirse ayar klasörü değişir; değiştirmeyin.**

- Kurulum / güncelleme / yeniden kurulum bu klasöre **dokunmaz**.
- Kaldırma varsayılan olarak da silmez: etkileşimli kaldırmada "ayarlar da silinsin mi?" sorulur (varsayılan *Hayır*), sessiz kaldırmada asla silinmez.
- Geliştirme sürümleri ayarları eski `%APPDATA%\com.argbled\argb_controller\` klasörüne yazıyordu; yeni klasör yoksa kurulum bu verileri **bir kez kopyalar** (eski klasör silinmez).
  Bu taşıma kodu yazıldı ancak bu makinede yeni klasör zaten var olduğundan çalıştırılarak **denenmedi**.
- Aynı `AppId` (`C02320E8-F7E1-4A83-8E1D-09DE273120A7`) değiştirilmemelidir; aksi halde güncellemeler eski kurulumu tanımaz.

### Simge

Şu anki uygulama/kurulum simgesi **GEÇİCİ bir yer tutucudur** (`scripts\generate_placeholder_icon.py` ile üretilir: koyu zemin, gradyan güç halkası, beş renkli LED).
Kalıcı simge için `argb_controller_app\windows\runner\resources\app_icon.ico` dosyasını (çok boyutlu .ico: 16–256 px) değiştirmeniz yeterlidir.

### Pencere

Uygulama ≈ **550×750** (mantıksal px) boyutunda, çalışma alanının ortasında açılır (küçük ekranlarda ekrana sığdırılır). Pencere büyütülüp küçültülebilir; en küçük istemci boyutu 420×560'tır
(`windows\runner\main.cpp`, `win32_window.cpp`).

## Sürüm yayınlama kontrol listesi

1. `pubspec.yaml` sürümünü artırın → 2. betiği çalıştırın → 3. `.sha256` ile birlikte dağıtın (GitHub Release'e yükleyin) → 4. (varsa) imzalı yapın → 5. `git tag vX.Y.Z`.
