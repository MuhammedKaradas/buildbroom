# buildbroom

[English](README.md) · **Türkçe**

Geliştirici önbelleklerinin ve build kalıntılarının kapladığı disk alanını güvenle geri kazanın.

Çok sayıda repo üzerinde, ya da tek repoda birden fazla **git worktree** ile çalışıyorsan build
çıktıları hızla birikir: her worktree'nin kendi `node_modules`, `bin/obj`, `target`, `.next`, `build`
klasörü olur. Üstüne global önbellekler de eklenince (npm, Gradle, NuGet, Go, Docker build cache, Temp)
sistem diski birkaç haftada bir yeniden dolar. Her seferinde hangi klasörlerin güvenle silinebileceğini
yeniden araştırırsın.

buildbroom bu bilgiyi tek bir scriptte tutar ve **sen istemedikçe hiçbir şeyi silmez**.

> Durum: **Windows (PowerShell 5.1+)** ve **macOS (bash 3.2+)** bugün çalışıyor. Linux planlandı. Bkz. [ROADMAP](docs/ROADMAP.md).

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

## Hızlı başlangıç (macOS)

```bash
git clone https://github.com/MuhammedKaradas/buildbroom.git
cd buildbroom

unix/buildbroom.sh                                  # kuru çalıştırma: önbellekleri (+ config'teki köklerdeki kalıntıları) raporla
unix/buildbroom.sh --mode artifacts --roots ~/code,~/work
unix/buildbroom.sh --mode artifacts --roots ~/code --older-than-days 14 --apply
unix/buildbroom.sh --mode caches --apply
```

macOS ile gelen bash 3.2 ile çalışır, başka bir şey gerektirmez. `buildbroom` diye çağırmak için
`PATH`'teki bir yere link ver: `ln -s "$PWD/unix/buildbroom.sh" /usr/local/bin/buildbroom`.

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
| Docker build önbelleği | `docker builder prune -f`. İmajlara, container'lara ve volume'lere **dokunulmaz**. Boyut, `docker system df`'teki geri kazanılabilir build önbelleğidir |

`-Deep` ile ek olarak NuGet global paketleri ve Gradle wrapper dağıtımları da silinir. Bir sonraki
build bunları yeniden indirir.

**Sadece raporlanır, asla silinmez:** Docker Desktop / WSL sanal diskleri, Android SDK, Android
emülatörleri, İndirilenler. Alanın nereye gittiğini görebilmen için raporda gösterilirler.

#### macOS'ta

| Hedef | Nasıl |
|---|---|
| npm, Yarn, pnpm, Go build önbelleği | yukarıdaki komutlar (`~/.npm`, `~/Library/Caches/Yarn`, `~/Library/pnpm/store`, `go env GOCACHE`) |
| Gradle `caches/` + `daemon/` logları | Android Studio / IntelliJ açıkken **veya bir Gradle daemon'ı çalışırken** atlanır (daemon asla öldürülmez, önce `./gradlew --stop` çalıştır) |
| NuGet http + plugin önbelleği | `dotnet nuget locals ... --clear`. Rider açıkken atlanır |
| Xcode `DerivedData` | Xcode veya `xcodebuild` çalışırken atlanır |
| Xcode device support | sadece 90 gündür kullanılmayan `iOS/watchOS/... DeviceSupport` klasörleri. O cihaz bağlanınca Xcode yeniden kopyalar |
| CocoaPods önbelleği | `pod cache clean --all` |
| SwiftPM önbelleği | `~/Library/Caches/org.swift.swiftpm`. Xcode çalışırken atlanır |
| Homebrew | `brew cleanup` (eski indirmeler ve eski sürümler) |
| Docker build önbelleği | `docker builder prune -f`, sadece Docker çalışıyorsa |

`--deep` ile ek olarak: Go modül önbelleği (`go clean -modcache`), Gradle wrapper dağıtımları ve NuGet global paketleri.

**Sadece raporlanır:** Xcode arşivleri, iOS simülatörleri (`xcrun simctl delete unavailable` eskilerini siler),
Android SDK, Android emülatörleri. Docker'ın disk imajı ve `~/Downloads` ölçülmez, çünkü onları okumak macOS'un
klasör erişim izni sormasına yol açar.

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

### Eski git worktree'leri (sadece rapor, şimdilik macOS)

`--mode artifacts`, `all` (kök verildiyse) veya `worktrees` ile buildbroom, köklerin altındaki terk edilmiş
görünen bağlı git worktree'lerini de listeler:

- **folder is gone**: worktree klasörü elle silinmiş. Git'teki kaydını `git worktree prune` temizler
- **merged into main** (ya da `origin/HEAD`): branch'inde varsayılan branch'te olmayan hiçbir şey yok
- **last commit N d ago**: son commit `--stale-days` günden (varsayılan 30) eski

Her satır worktree'nin ne kadar yer kapladığını gösterir, **commit'lenmemiş değişiklik varsa** uyarır.
Worktree'ler asla silinmez: silmek için `git worktree remove <yol>` kullan, commit'lenmemiş iş varsa reddeder.
Kullanımdaki worktree'ler listelenmez.

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
   Tarama ve boyut ölçümü de reparse point'leri atlar. macOS'ta `rm -rf` bir symlink'i link olarak siler ve
   içine girmez. Tarama ve ölçüm de linkleri asla takip etmeyen `find -P` / `du -P` ile yapılır.
6. **Araç ve sistem klasörleri asla taranmaz:** `AppData`, `Program Files`, `ProgramData`,
   `Windows`, ayrıca `~\.vscode`, `~\.cursor`, `~\.nuget`, `~\.gradle`, `~\.cargo` gibi araç
   klasörleri. Oralardaki bir `node_modules` kurulu bir programa aittir (global npm, VS Code
   eklentileri, nvm). Bir `node_modules`'un içindeki paketler de asla proje sanılmaz.
   macOS'ta: `/System`, `/Library`, `/Applications`, `/usr`, `/opt` (Homebrew), `~/Library` ve `~/.nvm`,
   `~/.cargo`, `~/.gradle` gibi araç klasörleri, ayrıca `PATH`'teki Flutter SDK. Yollar, APFS'teki gibi büyük/küçük harf ayırmadan karşılaştırılır.
7. **Sürpriz tarama yok.** Varsayılan `all` modu, kalıntıları sadece senin verdiğin ya da config'e
   yazdığın köklerde arar. Kök verilmeden `-Mode artifacts` çalıştırılırsa bulunduğun klasörü tarar.
8. **Meşgul veya eksik araçlar.** Açık bir IDE'yi bozabilecek önbellek temizlikleri, o IDE açıkken
   atlanır. Aracı `PATH`'te olmayan önbellekler de atlanır ve raporda öyle görünür.
9. **Dürüst rapor.** `-Apply` sonrası boyutlar yeniden ölçülür. Rapor gerçekten ne kadar yer
   açıldığını gösterir, tamamen silinemeyen (dosyası kullanımda olan) klasörler işaretlenir.

## Seçenekler

| Windows | macOS | Varsayılan | Anlamı |
|---|---|---|---|
| `-Mode` | `--mode` | `all` | `all`, `caches` veya `artifacts`. macOS'ta ayrıca `worktrees` (sadece rapor) |
| `-Roots` | `--roots` | config, yoksa yok | kalıntı aranacak bir veya daha fazla klasör (virgülle ayrılmış ya da tekrarlanmış) |
| `-OlderThanDays` | `--older-than-days` | `7` | bundan daha yakın zamanda kullanılmış kalıntıları koru |
| `-TempDays` | | `3` | bundan yeni Temp öğelerini koru (macOS temp klasörünü kendisi temizler) |
| `-MaxDepth` | `--max-depth` | `8` | her kökün altında ne kadar derine inileceği |
| | `--stale-days` | `30` | son commit'i bundan eski worktree'leri raporla (config'te `staleDays`) |
| `-Exclude` | `--exclude` | | atlanacak yollar (joker karakterli), ör. `*\keep-me\*` / `*/keep-me/*` |
| `-NoGitCheck` | `--no-git-check` | kapalı | git reposu olmayan klasörlerdeki kalıntıları da temizle |
| `-Deep` | `--deep` | kapalı | yeniden indirmesi uzun süren büyük önbellekleri de sil (bkz. yukarısı) |
| `-Apply` | `--apply` | kapalı | gerçekten sil |
| `-Config` | `--config` | aşağıya bak | okunacak config dosyası |

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

macOS'ta dosya `~/.config/buildbroom/config.json` (ya da `$XDG_CONFIG_HOME` altında), yollar `"~/code"`
gibi yazılabilir. Dosya yerleşik `plutil` ile okunur (macOS 12 veya üstü).

Komut satırı seçenekleri config'i ezer.

## Düzenli çalıştırma

Bir-iki haftada bir çalıştır, kuru çalıştırma raporunu oku, sonra `-Apply` ile tekrarla.
Zamanlamak istersen Windows'ta Görev Zamanlayıcı'yı, macOS'ta `cron` ya da bir launchd agent'ı kullan. Önce `-Mode caches -Apply`'ı zamanla. Kalıntı
temizliğini ise ancak birkaç kuru çalıştırma doğru klasörleri seçtiğini gösterdikten sonra aç.

## Katkı

Bkz. [CONTRIBUTING.md](CONTRIBUTING.md). Lütfen [davranış kurallarına](CODE_OF_CONDUCT.md) uy, güvenlik
sorunlarını da [SECURITY.md](SECURITY.md)'de anlatıldığı gibi gizli olarak bildir.

## Lisans

[MIT](LICENSE)
