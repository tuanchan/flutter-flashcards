# Ma trận runtime Sync v2 Flutter - C#

Ngày chuẩn bị: 2026-08-14

## Điều kiện trước khi chạy

1. Chạy `assets/migrations/20260814_sync_v2.sql` trong Supabase SQL Editor.
2. Chạy lại chính migration lần thứ hai để xác nhận tính idempotent.
3. Xác nhận năm bảng `topics`, `courses`, `cards`, `card_examples`,
   `review_states` có `revision`, `last_device_id`, `last_mutation_id`,
   `deleted_at` và nằm trong publication `supabase_realtime`.
4. Tự chạy ứng dụng Flutter theo quy trình của dự án. Codex không chạy lệnh
   Flutter theo chỉ dẫn trong `AGENTS.md`.
5. Mở ứng dụng C# bằng bản vừa build và đăng nhập cùng tài khoản Supabase.

## Truy vấn quan sát

```sql
select id, revision, last_device_id, last_mutation_id, updated_at, deleted_at
from public.cards
where owner_id = 'USER_UUID_HERE'::uuid
order by updated_at desc
limit 20;

select owner_id, mutation_id, device_id, table_name, entity_id, created_at
from public.sync_mutation_receipts
where owner_id = 'USER_UUID_HERE'::uuid
order by created_at desc
limit 50;
```

Không ghi token hoặc toàn bộ payload người dùng vào log kiểm thử.

## Kịch bản bắt buộc

| Mã | Thao tác | Kết quả cần xác nhận |
|---|---|---|
| M01 | Flutter tạo topic, course và một card khi C# đang mở | C# nhận từng row; card không tạo chuỗi GET toàn bảng |
| M02 | C# tạo rồi sửa đúng một card khi Flutter đang mở | Flutter nhận đúng card; request không upload toàn course |
| M03 | Hai app sửa hai card khác nhau trong cùng course | Cả hai thay đổi cùng tồn tại, không row nào bị mất |
| M04 | Hai app sửa cùng một card từ cùng revision | Một mutation bị conflict; app báo lỗi, không âm thầm ghi đè |
| M05 | Flutter tạo card khi C# offline rồi mở lại C# | Delta catch-up tạo card; lần lưu course C# không tombstone card đó |
| M06 | C# tạo card khi Flutter offline rồi mở lại Flutter | Delta catch-up tạo card; snapshot local cũ không ghi đè |
| M07 | Hai app học hai card khác nhau | Hai RPC SRS độc lập; ba nơi có cùng trạng thái |
| M08 | Hai app học cùng card gần đồng thời | RPC khóa row; mutation sau rebase hoặc báo conflict rõ |
| M09 | Tắt mạng sau local commit, trước server ACK | Outbox còn row; có mạng lại thì retry thành công |
| M10 | Chặn response sau khi server commit | Retry cùng mutation ID không tăng count/revision lần hai |
| M11 | Ngắt WebSocket, sửa bên app kia, rồi reconnect | Delta cursor lấy đủ event bị lỡ |
| M12 | Xóa topic/course/card/example từ Flutter | Chỉ ID explicit có tombstone; C# không nhận `card_examples` vì đã loại subscription có chủ ý |
| M13 | Xóa topic/course/card từ C# | Flutter ẩn/xóa đúng row và con theo tombstone RPC |
| M14 | Gây lỗi payload vĩnh viễn | Retry dừng sau giới hạn và có dead-letter/log; không tight loop |
| M15 | Sửa ảnh/audio/cache local | Không binary nào được upload hoặc xóa bởi database sync |

## Ghi kết quả

Với mỗi mã, ghi: thời điểm, app phát mutation, `mutation_id`, revision trước/sau,
số request quan sát được, kết quả Flutter, kết quả C#, kết quả Supabase và log lỗi
nếu có. SYNC-09 chỉ được đánh dấu hoàn tất khi M01-M15 đều đạt trên hai tiến trình
thật dùng cùng Supabase project.
