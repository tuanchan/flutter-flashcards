# Kế hoạch sửa đồng bộ Flutter - C#

Tài liệu này chia việc sửa đồng bộ thành từng nhiệm vụ độc lập. Chỉ thực hiện
một nhiệm vụ tại một thời điểm, kiểm tra xong và cập nhật trạng thái trước khi
chuyển sang nhiệm vụ tiếp theo.

## Phạm vi

- Flutter: `D:\FLUTTER\flutterflashcard\demo5th5`
- C#: `D:\CSharp\TocflQuiz\FlashCards`
- Hai ứng dụng dùng chung một Supabase project.
- Các bảng realtime chính: `topics`, `courses`, `cards`, `card_examples`,
  `review_states`.
- Ảnh, âm thanh và file cache vẫn lưu local; không đưa binary vào luồng
  realtime database.

## Quy tắc thực hiện

- [ ] Mỗi lần chỉ làm đúng một task bên dưới.
- [ ] Không gộp nhiều task vào một lần sửa.
- [ ] Trước mỗi task, đọc lại phiên bản mới nhất của các file được liệt kê.
- [ ] Không chạy `flutter`, `flutter pub get`, `flutter build` hoặc lệnh Flutter
  khác. Người dùng tự chạy các bước Flutter.
- [ ] Không dùng việc thiếu row trong snapshot local để suy ra rằng row trên
  server phải bị xóa.
- [ ] Không xóa outbox/event trước khi server hoặc local xác nhận đã áp dụng.
- [ ] Mọi migration SQL phải có thể chạy lặp lại an toàn hoặc có bước kiểm tra
  tồn tại trước khi tạo.
- [ ] Không ghi access token, refresh token, anon key hoặc payload nhạy cảm vào
  log.
- [ ] Sau mỗi task, ghi rõ: file đã sửa, kiểm tra tĩnh đã chạy, phần runtime nào
  người dùng còn phải tự xác nhận.

## Trạng thái tổng thể

| Task | Nội dung | Trạng thái |
|---|---|---|
| SYNC-01 | Tạo hợp đồng mutation và revision dùng chung | Đã triển khai - chờ runtime |
| SYNC-02 | Không làm rơi batch realtime khi C# đang bận | Đã triển khai - chờ runtime |
| SYNC-03 | Chỉ xóa bằng tombstone/mutation explicit | Đã triển khai - chờ runtime |
| SYNC-04 | Flutter targeted upsert theo row | Đã triển khai - chờ runtime |
| SYNC-05 | C# targeted upsert theo row | Đã triển khai - chờ runtime |
| SYNC-06 | C# áp dụng trực tiếp payload realtime | Đã triển khai - chờ runtime |
| SYNC-07 | C# xử lý đầy đủ `card_examples` | Đã chốt loại khỏi C# |
| SYNC-08 | Thống nhất SRS bằng Supabase RPC | Đã triển khai - chờ runtime |
| SYNC-09 | Chạy ma trận kiểm tra chéo hai ứng dụng | Đã chuẩn bị - chưa chạy |

---

## SYNC-01 - Hợp đồng mutation và revision dùng chung

> Cập nhật 2026-08-14: đã thêm migration `20260814_sync_v2.sql`, metadata
> SQLite/C# và device/mutation ID bền vững. C# build đạt 0 lỗi; migration và
> Flutter còn phải xác nhận runtime sau khi người dùng chạy migration/app.

### Mục tiêu

Phân biệt thay đổi của từng thiết bị, nhận biết echo của chính ứng dụng và phát
hiện ghi đè trên dữ liệu cũ mà không dựa vào cửa sổ thời gian 3 giây.

### File dự kiến

- `assets/supabase_flashcards_schema.sql`
- Tạo migration SQL riêng cho sync v2.
- `lib/core/network/supabase_sync_service.dart`
- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.cs`
- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.Realtime.cs`
- Model/settings lưu `device_id` của C#.

### Việc cần làm

- [ ] Chốt hợp đồng chung cho năm bảng realtime:
  - `revision bigint not null default 1`
  - `last_device_id text`
  - `last_mutation_id uuid`
  - `updated_at` do server cấp.
- [ ] Tạo trigger tăng `revision` trên mỗi UPDATE thực sự.
- [ ] Mỗi app tạo và lưu bền vững một `device_id`.
- [ ] Mỗi thao tác local tạo một `mutation_id` mới và giữ nguyên ID đó khi retry.
- [ ] Server trả lại `id`, `revision`, `updated_at`, `last_device_id`,
  `last_mutation_id` sau upsert.
- [ ] Local lưu revision server gần nhất theo row.
- [ ] Chỉ bỏ realtime echo khi `last_device_id` và `last_mutation_id` trùng với
  mutation đã được server xác nhận; không bỏ theo thời gian.
- [ ] Quy định xung đột: update chỉ hợp lệ khi `base_revision` bằng revision
  hiện tại; nếu lệch phải pull row mới và báo conflict/rebase.

### Hoàn thành khi

- Hai app tạo mutation có ID khác nhau.
- Retry cùng mutation không tạo tác dụng lặp.
- Thay đổi từ app còn lại không bị nhận nhầm là self-echo.
- Update dựa trên revision cũ không âm thầm ghi đè row mới.

---

## SYNC-02 - Giữ lại batch realtime C# khi đang bận

> Cập nhật 2026-08-14: `SupabaseSyncService.Realtime.cs` giữ queue theo row,
> chỉ ACK từng event sau commit, retry/backoff/dead-letter và delta catch-up;
> đã bỏ cửa sổ bỏ event 3 giây. Cần đo runtime lúc gate đang bận/reconnect.

### Mục tiêu

Không làm mất event Flutter gửi đến khi C# đang sync, đang mutation hoặc vừa
hoàn tất mutation.

### File dự kiến

- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.Realtime.cs`
- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.cs`

### Việc cần làm

- [ ] Không `_pendingChanges.Clear()` trước khi biết batch có thể áp dụng.
- [ ] Dedupe queue theo `(table, id)` và giữ event mới nhất của row.
- [ ] Nếu `_mutationGate` đang bận, giữ queue và lên lịch chạy lại.
- [ ] Xóa từng event chỉ sau khi `ApplyIncrementalChangeAsync` thành công.
- [ ] Event lỗi tạm thời phải được retry với backoff có giới hạn.
- [ ] Event lỗi vĩnh viễn chuyển sang dead-letter/log chẩn đoán, không chặn toàn
  bộ queue.
- [ ] Sau khi WebSocket reconnect, chạy delta catch-up dựa trên revision hoặc
  cursor server.
- [ ] Bỏ điều kiện bỏ event theo `_lastLiveMutationFinishedUtc < 3 giây` sau khi
  SYNC-01 đã phân biệt được self-echo.

### Hoàn thành khi

- Event đến trong lúc C# đang upload vẫn được áp dụng sau khi upload kết thúc.
- Reconnect không bỏ sót thay đổi xảy ra trong thời gian mất WebSocket.
- Queue không tăng vô hạn khi nhiều event của cùng một row đến liên tục.

---

## SYNC-03 - DELETE bằng tombstone/mutation explicit

> Cập nhật 2026-08-14: đã bỏ suy luận DELETE từ snapshot thiếu row; Flutter
> ghi tombstone bằng trigger cùng transaction, C# ghi mutation trước xóa local,
> và RPC cascade course/card trong transaction server. Cần kiểm thử xóa chéo.

### Mục tiêu

Không bao giờ xóa row server chỉ vì row đó không tồn tại trong snapshot local
có thể đã cũ.

### File dự kiến

- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.cs`
- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.OfflineSync.cs`
- `lib/core/network/supabase_sync_service.dart`
- Các nơi xóa topic/course/card trong cả hai ứng dụng.

### Việc cần làm

- [ ] Loại bỏ logic C# đưa toàn bộ `remoteCardsById.Keys` còn dư vào danh sách
  xóa.
- [ ] Khi người dùng xóa, tạo mutation cụ thể gồm `table`, `remote_id`,
  `mutation_id`, `base_revision`, `deleted_at`.
- [ ] Lưu tombstone vào outbox trước khi thay đổi biến mất khỏi local UI.
- [ ] Chỉ đánh dấu `deleted_at` cho đúng ID được người dùng xóa.
- [ ] Xóa course phải có quy tắc rõ cho card con; ưu tiên transaction/RPC phía
  server.
- [ ] Retry delete phải idempotent.
- [ ] Pull/realtime nhận tombstone mới hơn thì xóa hoặc ẩn row local.
- [ ] Tombstone cũ hơn mutation local chưa gửi không được thắng tự động.

### Hoàn thành khi

- Flutter tạo thẻ mới trong lúc C# offline; lần lưu course tiếp theo trên C#
  không xóa thẻ đó.
- Delete explicit từ một app vẫn truyền sang app còn lại.
- Retry delete nhiều lần không tạo lỗi hoặc xóa nhầm row khác.

---

## SYNC-04 - Flutter targeted upsert theo row

> Cập nhật 2026-08-14: `app_database.dart` và
> `supabase_sync_service.dart` có outbox v2, năm API targeted, dependency theo
> remote UUID và retry/conflict. Các màn hình CRUD dùng trigger SQLite; không
> chạy lệnh Flutter theo `AGENTS.md`, nên còn chờ người dùng xác nhận runtime.

### Mục tiêu

Một thay đổi local chỉ push entity bị thay đổi và dependency thực sự cần thiết,
không chạy `livePush` qua chín bảng.

### File dự kiến

- `lib/core/network/supabase_sync_service.dart`
- `lib/core/database/app_database.dart`
- Các màn hình tạo/sửa/xóa topic, course, card, example và SRS.

### Việc cần làm

- [ ] Mở rộng `sync_outbox` để chứa `table`, `entity_id`, `operation`,
  `mutation_id`, `base_revision`, thời điểm và trạng thái retry.
- [ ] Tạo các API targeted:
  - `pushTopicMutation`
  - `pushCourseMutation`
  - `pushCardMutation`
  - `pushCardExampleMutation`
  - `pushReviewStateMutation`
- [ ] Ghi local data và outbox trong cùng SQLite transaction.
- [ ] Upsert đúng một row hoặc một batch row cùng loại.
- [ ] Không gọi `_prepareIdentityMaps()` tải toàn bộ `topics/courses/cards` cho
  mỗi thao tác.
- [ ] Lưu remote UUID trực tiếp trong local mapping bền vững.
- [ ] Chỉ push parent trước khi parent chưa có remote UUID.
- [ ] Giữ cơ chế full snapshot cho startup/recovery, không dùng nó làm đường
  push thông thường.
- [ ] Giữ ảnh/audio local; database chỉ sync metadata/path theo quy ước đã chốt.

### Hoàn thành khi

- Sửa một card chỉ tạo request cho card đó.
- Sửa favorite/archive không quét các bảng không liên quan.
- Mất mạng vẫn lưu mutation và retry được sau khi có mạng.
- Không còn gọi `syncPendingChanges()` kiểu full `livePush` ở các thao tác CRUD
  realtime.

---

## SYNC-05 - C# targeted upsert theo row

> Cập nhật 2026-08-14: thêm `SupabaseSyncService.SyncV2.cs`, metadata model/file
> và chuyển cả queue offline legacy sang mutation row. Hash chỉ queue card đổi;
> C# build đạt 0 lỗi, cần xác nhận request thực tế bằng runtime/network log.

### Mục tiêu

Không upload toàn bộ course, toàn bộ card và toàn bộ SRS chỉ vì một card vừa
thay đổi.

### File dự kiến

- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.cs`
- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.OfflineSync.cs`
- `D:\CSharp\TocflQuiz\FlashCards\Services\CardSetStorage.cs`
- Các form/control chỉnh sửa card, course và SRS.

### Việc cần làm

- [ ] Thay `NotifyLocalSetSaved` bằng notification có phạm vi mutation cụ thể.
- [ ] Tạo API push topic/course/card/review riêng.
- [ ] Một card edit chỉ PATCH/upsert card đó.
- [ ] Một lần trả lời chỉ upsert `review_states` của card đó hoặc batch các card
  vừa học khi kết thúc phiên.
- [ ] Không GET toàn bộ `review_states` của tài khoản trước mỗi SRS update.
- [ ] Không PATCH tuần tự mọi card khác nội dung; batch khi thật sự có nhiều
  thay đổi.
- [ ] Coalesce nhiều mutation đang chờ của cùng row thành trạng thái mới nhất.
- [ ] Pending queue lưu mutation cụ thể, không chỉ lưu course ID.

### Hoàn thành khi

- Sửa một card tạo tối đa một card upsert cùng request dependency cần thiết.
- Một cập nhật SRS không GET hàng trăm `review_states` khác.
- Nhiều lần lưu nhanh cùng card không tạo hàng dài upload toàn course.

---

## SYNC-06 - C# áp dụng trực tiếp payload realtime

> Cập nhật 2026-08-14: event giữ bản sao `record`/`old_record`, validate owner,
> parent và revision, gom ghi file theo course rồi mới báo UI. Đường event card
> thường không REST GET; cần đo số request ở runtime.

### Mục tiêu

Loại bỏ độ trễ REST GET từng row sau khi WebSocket đã gửi `record` và
`old_record`.

### File dự kiến

- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.Realtime.cs`

### Việc cần làm

- [ ] `PendingRealtimeChange` giữ bản sao đầy đủ `record` và `old_record`.
- [ ] Validate `owner_id`, ID cha và revision trước khi áp dụng.
- [ ] INSERT/UPDATE dùng trực tiếp `record`.
- [ ] DELETE dùng `old_record` hoặc tombstone explicit.
- [ ] Chỉ REST GET fallback khi payload thiếu trường bắt buộc.
- [ ] Gom nhiều thay đổi cùng course và chỉ ghi file course một lần mỗi batch.
- [ ] Chỉ phát `RemoteDataChanged` sau khi toàn bộ batch đã commit local.

### Hoàn thành khi

- Một event card thông thường không phát sinh REST GET.
- Batch 28 card không tạo 28-56 GET tuần tự.
- Dữ liệu local sau apply khớp revision/payload server.

---

## SYNC-07 - C# xử lý `card_examples`

> Cập nhật 2026-08-14: quyết định loại `card_examples` khỏi subscription và
> delta C# vì C# chỉ có cache ví dụ Gemini theo course, không có model DB tương
> thích. Flutter/Supabase vẫn đồng bộ bảng này; C# không còn ACK giả event.

### Mục tiêu

Không còn tình trạng đăng ký realtime `card_examples` nhưng nhận event rồi bỏ
qua mà không cập nhật local.

### File dự kiến

- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.Realtime.cs`
- Model/file local đang chứa ví dụ của card.
- `D:\CSharp\TocflQuiz\FlashCards\Services\SupabaseSyncService.cs`

### Việc cần làm

- [ ] Xác định model local chính thức cho example.
- [ ] Map đủ `id`, `card_id`, `example_text`, `pronunciation`, `meaning`,
  `updated_at` và metadata sync v2.
- [ ] Xử lý INSERT, UPDATE, DELETE/tombstone.
- [ ] Targeted push example local lên server.
- [ ] Nếu C# không sử dụng example từ database, bỏ subscription một cách rõ
  ràng thay vì giả vờ đã hỗ trợ.

### Hoàn thành khi

- Example tạo/sửa/xóa từ Flutter xuất hiện đúng trên C# hoặc bảng này được loại
  khỏi phạm vi C# bằng quyết định được ghi rõ.
- Event `card_examples` không còn được đánh dấu xử lý thành công khi thực tế
  không làm gì.

---

## SYNC-08 - Thống nhất SRS bằng Supabase RPC

> Cập nhật 2026-08-14: migration có `apply_srs_review_v2`; Flutter và C# queue
> immutable answer event, dùng cùng Again/Hard/Good/Easy và áp response server
> về local. Đã xử lý retry idempotent và rebase chuỗi review offline; cần chạy
> hai app thật để xác nhận ngày ôn/múi giờ.

### Mục tiêu

Hai ứng dụng cho cùng kết quả SRS và không ghi đè toàn bộ trạng thái dựa trên
snapshot cũ.

### File dự kiến

- Migration SQL tạo RPC SRS.
- `lib/core/utils/app_helpers_part_01.dart`
- Các nơi Flutter gọi `ReviewScheduler.nextState`.
- `D:\CSharp\TocflQuiz\FlashCards\Services\SpacedRepetitionService.cs`
- Các nơi C# áp dụng review.

### Việc cần làm

- [ ] Chốt duy nhất một bảng interval và quy tắc Again/Hard/Good/Easy.
- [ ] Chốt ý nghĩa của `level`, `ease_factor`, `interval_days`,
  `repetition_count`, `correct_count`, `wrong_count`.
- [ ] Tạo RPC nhận `card_id`, kết quả trả lời, `reviewed_at`, `mutation_id`,
  `base_revision`.
- [ ] RPC khóa row, kiểm tra revision, tính trạng thái mới và ghi trong một
  transaction.
- [ ] RPC trả toàn bộ `review_states` sau cập nhật.
- [ ] Flutter và C# áp dụng response RPC vào local, không tự tính hai thuật toán
  khác nhau trong đường production.
- [ ] Mutation ID bảo đảm một câu trả lời retry không tăng count hai lần.
- [ ] Xử lý conflict khi hai app trả lời cùng card gần như đồng thời.

### Hoàn thành khi

- Cùng input và trạng thái đầu vào cho kết quả giống nhau trên cả hai app.
- Again/Hard/Good/Easy có cùng level và ngày ôn.
- Retry cùng mutation không tăng `repetition_count` lần hai.
- Hai mutation khác nhau trên cùng card được serialize hoặc báo conflict rõ.

---

## SYNC-09 - Ma trận kiểm tra chéo

> Cập nhật 2026-08-14: đã tạo `SYNC_V2_RUNTIME_CHECKLIST.md` với 15 kịch bản và
> truy vấn quan sát. Chưa đánh dấu hoàn tất vì migration chưa được deploy và
> Codex không được chạy Flutter; người dùng cần chạy hai ứng dụng thật.

Chỉ thực hiện sau khi SYNC-01 đến SYNC-08 hoàn thành.

### Kịch bản bắt buộc

- [ ] Flutter tạo topic/course/card; C# đang mở nhận đúng dữ liệu.
- [ ] C# tạo/sửa card; Flutter đang mở nhận đúng dữ liệu.
- [ ] Hai app sửa hai card khác nhau trong cùng course cùng lúc.
- [ ] Hai app sửa cùng một card; conflict được phát hiện, không âm thầm ghi đè.
- [ ] Flutter tạo card khi C# offline; mở lại C# không soft-delete card.
- [ ] C# tạo card khi Flutter offline; Flutter catch-up không ghi đè bằng local
  cũ.
- [ ] Hai app học hai card khác nhau cùng lúc.
- [ ] Hai app học cùng một card gần như đồng thời.
- [ ] Mất mạng sau khi ghi local nhưng trước server ack.
- [ ] Server đã commit nhưng client mất mạng trước khi nhận ack.
- [ ] WebSocket ngắt rồi reconnect; delta catch-up lấy đủ event bị lỡ.
- [ ] Delete topic/course/card/example từ mỗi app.
- [ ] Retry lỗi vĩnh viễn không tạo tight loop và có log chẩn đoán.
- [ ] Ảnh/audio/cache local không bị xóa hoặc upload ngoài ý muốn.

### Tiêu chí cuối

- Không mất row.
- Không resurrect row đã xóa.
- Không soft-delete dựa trên snapshot local thiếu dữ liệu.
- Không có push/realtime ping-pong.
- Không có retry tight loop.
- Cùng trạng thái SRS trên Flutter, C#, Supabase.
- Thời gian nhận một thay đổi đơn lẻ không bao gồm full-table scan.

## Cách giao task cho lần tiếp theo

Ví dụ:

> Thực hiện duy nhất SYNC-02 trong `TASK_SYNC_FLUTTER_CSHARP.md`, không làm task
> khác và không chạy Flutter.

Sau khi hoàn thành, đổi trạng thái task tương ứng thành `Đã làm`, ghi ngày và
tóm tắt file đã sửa ngay dưới task đó.
