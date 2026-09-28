# TrapPyramidPro (XAUUSD M5)

`TrapPyramidPro.mq5` → MetaEditor'da açıp **F7** ile derleyin. Dosya UTF-8 (BOM'lu) kaydedildi, Türkçe karakterler bozulmamalı.

v1.60'ın varsayılan ayarları, v1.50'nin davranışını **hata düzeltmeleri dışında** korur. İlk koşuyu aynı ayarlarla yapıp
v1.50 sonucuyla karşılaştırın; böylece düzeltmelerin etkisini ayrı görürsünüz.

## v1.60'ta ne değişti

| Konu | v1.50 | v1.60 |
|---|---|---|
| Kapanıştan sonra yeni giriş | `lastBarTime` pozisyon açıkken güncellenmiyordu → SL/TP'den hemen sonra, aynı bar içinde, hareketin ucunda yeni tuzak | En erken bir sonraki bar; `InpCooldownBars` ile uzatılabilir |
| Pyramid "BE" | Tüm SL'ler eski ortalamaya çekiliyordu; n pozisyonda SL'e dönüşte grup zararı ≈ n × adım / 2 (3 pozisyonda ilk riskten büyük) | Grup zararı en fazla `InpPyramidRiskR` × ilk risk (0 = komisyon dahil gerçek başabaş), SL asla geri çekilmez |
| Pyramid adımı | En son açılan pozisyona göre (saniye çözünürlüğü) | En uç giriş fiyatına göre |
| Spread | Sadece emir kurarken kontrol | Bekleyen emir varken her tick; spread açılırsa emirler silinir |
| `InpRefreshATR = 0` | Her bar yenileme | Yenileme kapalı |
| Emir süresi | Her zaman `ORDER_TIME_SPECIFIED` | Broker desteklemiyorsa GTC + EA'nın kendi süre takibi |
| Günlük zarar | Sabit 25 $ | Bakiyenin %'si (`2.5` = 1000 $'da 25 $) |

## Yeni girdiler

| Girdi | Varsayılan | Açıklama |
|---|---|---|
| `InpEntryMode` | Stop tuzak | **Stop tuzak** (v1.50), **Kanal kırılımı** (son `InpRangeBars` barın tepe/dibi + tampon, kanal en fazla `InpRangeMaxATR` × ATR genişlikteyse), **Limit fade** (fiyat düşünce Buy Limit, yükselince Sell Limit) |
| `InpCooldownBars` | 1 | İşlem grubu kapandıktan sonra beklenecek bar |
| `InpMaxGroupsPerDay` | 0 | Günlük en fazla yeni işlem grubu (0 = sınırsız) |
| `InpUseADX`, `InpADXMinBreakout`, `InpADXMaxFade` | kapalı, 25, 20 | Kırılım modları sadece ADX yüksekken, fade sadece ADX düşükken |
| `InpMinATRtoSpread` | 0 | ATR, spread'in bu katından küçükse işlem yok |
| `InpPyramidRiskR` | 1.0 | Pyramid sonrası ortak SL'de grubun en fazla zararı (ilk risk cinsinden) |

## Önerilen test planı

Modelleme: **Gerçek tiklere dayalı her tik**, gecikme: rastgele (veya ≥ 50 ms). En az 6–12 ay; tek bir ay üzerinde optimizasyon yapmayın.

1. **Temel çizgi**: v1.60 varsayılan ayarlar ve aynı dönem. v1.50 ile karşılaştırın.
2. **Ayna testi** (kaybın kaynağını ayırır). A ve B'nin gerçekten birbirinin tersi olması için şunları sabit tutun:
   `InpEnablePyramid = false`, `InpMaxDailyLossPct = 0`, `InpUseADX = false`, `InpRiskPercent = 0`, `InpCommissionPerLot = 0`
   - A: Mod = Stop tuzak, SL = 1.0, TP = 1.8
   - B: Mod = Limit fade, SL = 1.8, TP = 1.0 (A ile aynı noktadan giren, SL/TP'si yer değiştirmiş ters işlem)
   - Yön etkisi ≈ (A − B) / 2, maliyet ≈ −(A + B) / 2. B kârlıysa kayıp, kırılımların geri dönmesinden (ortalamaya dönüş) geliyor.
3. **Filtreler** (her seferinde tek değişiklik): `InpUseTrend = true` → `InpCooldownBars = 3..6` → `InpUseADX = true` → `InpMinATRtoSpread = 10`.
4. **Kanal kırılımı**: `InpEntryMode = Kanal kırılımı`, SL 1.5, TP 3.0, trend filtresi açık.
5. Pyramid'i ancak temel giriş kendi başına kâr ediyorsa açın (`InpPyramidRiskR` 0–1).

Her koşuda raporda **toplam işlem, kârlı işlem %, uzun/kısa kazanç %, kâr faktörü, beklenen getiri** ve Günlük sekmesindeki
`v1.60 kapandı ...` satırlarına (atlanan bar sayaçları) bakın.
