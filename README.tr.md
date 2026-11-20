# buildbroom

[English](README.md) · **Türkçe**

Geliştirici önbelleklerinin ve build kalıntılarının kapladığı disk alanını güvenle geri kazanın.

Çok sayıda repo üzerinde, ya da tek repoda birden fazla **git worktree** ile çalışıyorsan build
çıktıları hızla birikir: her worktree'nin kendi `node_modules`, `bin/obj`, `target`, `.next`, `build`
klasörü olur. Üstüne global önbellekler de eklenince (npm, Gradle, NuGet, Go, Docker build cache, Temp)
sistem diski birkaç haftada bir yeniden dolar. Her seferinde hangi klasörlerin güvenle silinebileceğini
yeniden araştırırsın.

buildbroom bu bilgiyi tek bir scriptte tutar ve **sen istemedikçe hiçbir şeyi silmez**.

> Durum: **Windows (PowerShell 5.1+)** bugün çalışıyor. macOS ve Linux planlandı. Bkz. [ROADMAP](docs/ROADMAP.md).

## Hızlı başlangıç (Windows)

```powershell
git clone https://github.com/MuhammedKaradas/buildbroom.git
cd buildbroom

.\buildbroom.cmd                              # kuru çalıştırma: önbellekleri (+ config'teki köklerdeki kalıntıları) raporla
.\buildbroom.cmd -Mode artifacts -Roots D:\code,E:\work
.\buildbroom.cmd -Mode artifacts -Roots D:\code -OlderThanDays 14 -Apply
.\buildbroom.cmd -Mode caches -Apply
```

`buildbroom.cmd` sadece `windows\buildbroom.ps1`'i `-ExecutionPolicy Bypass` ile çalıştırır. Böylece
execution policy ayarını değiştirmen gerekmez. İstersen `.ps1`'i doğrudan da çağırabilirsin.

## Neleri temizler

### `caches` (global, yeniden indirilebilir)

| Hedef | Nasıl |
|---|---|
| npm önbelleği | `npm cache clean --force` |
| Yarn önbelleği | `yarn cache clean` |
| pnpm store | `pnpm store prune` (sadece hiçbir projenin kullanmadığı paketler) |
| Go build önbelleği | `go clean -cache` |
| Gradle `caches/` + `daemon/` logları | önce Gradle daemon'larını durdurur. Android Studio / IntelliJ açıkken atlanır |
| NuGet http + plugin önbelleği | `dotnet nuget locals ... --clear`. Visual Studio / Rider açıkken atlanır |
| Temp | sadece içinde `-TempDays` gündür (varsayılan 3) hiçbir şey yazılmamış üst seviye öğeler |
| Crash dump'lar | `%LOCALAPPDATA%\CrashDumps` |
| Docker build önbelleği | `docker builder prune -f`. İmajlara, container'lara ve volume'lere **dokunulmaz** |

`-Deep` ile ek olarak NuGet global paketleri ve Gradle wrapper dağıtımları da silinir. Bir sonraki
build bunları yeniden indirir.

**Sadece raporlanır, asla silinmez:** Docker Desktop / WSL sanal diskleri, Android SDK, Android
emülatörleri, İndirilenler. Alanın nereye gittiğini görebilmen için raporda gösterilirler.

### `artifacts` (proje bazında, `-Roots` altında)

| Klasör | Sadece üst klasörde şu varsa |
|---|---|
| `node_modules`, `.next`, `.nuxt`, `.svelte-kit`, `.parcel-cache`, `dist` | `package.json` |
| `.turbo` | `package.json` / `turbo.json` |
| `.angular` | `angular.json` |
| `bin`, `obj` | `*.csproj` / `*.fsproj` / `*.vbproj` |
| `target` | `Cargo.toml` / `pom.xml` |
| `build`, `.gradle` | Gradle / Flutter / CMake proje dosyaları |
| `.dart_tool` | `pubspec.yaml` |
| `__pycache__`, `.pytest_cache`, `.mypy_cache` | Python dosyaları |

## Güvenlik modeli

1. **Varsayılan kuru çalıştırma.** `-Apply` verilmezse buildbroom sadece rapor basar.
2. **Proje dosyası kontrolü.** `build` adlı bir klasör, ancak yanında gerçek bir proje dosyası varsa aday olur.
3. **Git kontrolü.** Bir aday ancak `git check-ignore` onu yok sayılan (ignored) olarak işaretliyorsa
   silinir. Böylece commit'lenmiş bir `dist/` veya `bin/` asla silinmez. Git reposu olmayan
   klasörler, `-NoGitCheck` verilmedikçe korunur.
4. **Yaş kontrolü.** Klasörün *içinde* son `-OlderThanDays` gün (varsayılan 7) içinde yazılmış
   herhangi bir dosya varsa klasör korunur. Böylece şu an çalıştığın worktree olduğu gibi kalır.
   (Klasörün kendi tarihi yetmez: Windows, derindeki dosyalar değişince onu güncellemez.)
5. **Junction'lar takip edilmez.** Klasörler `rmdir /s /q` ile silinir. Bu komut junction ve
   symlink'leri içine girmeden kaldırır. Yani `node_modules` içindeki bir pnpm veya monorepo
   workspace linki, gösterdiği gerçek kaynak kodu da beraberinde götürmez. (Bazı eski PowerShell
   sürümlerinde `Remove-Item -Recurse` linkleri takip edebiliyordu. buildbroom ona güvenmez.)
   Tarama ve boyut ölçümü de reparse point'leri atlar.
6. **Araç ve sistem klasörleri asla taranmaz:** `AppData`, `Program Files`, `ProgramData`,
   `Windows`, ayrıca `~\.vscode`, `~\.cursor`, `~\.nuget`, `~\.gradle`, `~\.cargo` gibi araç
   klasörleri. Oralardaki bir `node_modules` kurulu bir programa aittir (global npm, VS Code
   eklentileri, nvm). Bir `node_modules`'un içindeki paketler de asla proje sanılmaz.
7. **Sürpriz tarama yok.** Varsayılan `all` modu, kalıntıları sadece senin verdiğin ya da config'e
   yazdığın köklerde arar. Kök verilmeden `-Mode artifacts` çalıştırılırsa bulunduğun klasörü tarar.
8. **Meşgul veya eksik araçlar.** Açık bir IDE'yi bozabilecek önbellek temizlikleri, o IDE açıkken
   atlanır. Aracı `PATH`'te olmayan önbellekler de atlanır ve raporda öyle görünür.
9. **Dürüst rapor.** `-Apply` sonrası boyutlar yeniden ölçülür. Rapor gerçekten ne kadar yer
   açıldığını gösterir, tamamen silinemeyen (dosyası kullanımda olan) klasörler işaretlenir.

## Seçenekler

| Seçenek | Varsayılan | Anlamı |
|---|---|---|
| `-Mode` | `all` | `all`, `caches` veya `artifacts` |
| `-Roots` | config, yoksa yok | kalıntı aranacak bir veya daha fazla klasör |
| `-OlderThanDays` | `7` | bundan daha yakın zamanda kullanılmış kalıntıları koru |
| `-TempDays` | `3` | bundan yeni Temp öğelerini koru |
| `-MaxDepth` | `8` | her kökün altında ne kadar derine inileceği |
| `-Exclude` | | atlanacak yollar (joker karakterli), ör. `*\keep-me\*` |
| `-NoGitCheck` | kapalı | git reposu olmayan klasörlerdeki kalıntıları da temizle |
| `-Deep` | kapalı | NuGet global paketlerini ve Gradle wrapper dağıtımlarını da sil |
| `-Apply` | kapalı | gerçekten sil |

## Config dosyası

Kökleri her seferinde yazmamak için `%USERPROFILE%\.config\buildbroom\config.json` dosyasına koy
(bkz. [`config.example.json`](config.example.json)):

```json
{
  "roots": ["D:\\code", "E:\\work"],
  "olderThanDays": 7,
  "exclude": ["*\\vendor-snapshots\\*"]
}
```

Komut satırı seçenekleri config'i ezer.

## Düzenli çalıştırma

Bir-iki haftada bir çalıştır, kuru çalıştırma raporunu oku, sonra `-Apply` ile tekrarla.
Zamanlamak istersen Görev Zamanlayıcı'yı kullan. Önce `-Mode caches -Apply`'ı zamanla. Kalıntı
temizliğini ise ancak birkaç kuru çalıştırma doğru klasörleri seçtiğini gösterdikten sonra aç.

## Lisans

[MIT](LICENSE)
