-- =====================================================================
-- Phân tích độ khó và hành trình người chơi – Flood-It! (dữ liệu public)
-- Chạy trên Google BigQuery (bản sandbox miễn phí).
-- Nguồn: firebase-public-project.analytics_153293282.events_*
--        (game puzzle Flood-It!, dữ liệu Firebase khoảng 06/2018 – 10/2018)
--
-- Cách chạy: mở console.cloud.google.com/bigquery, chọn project của bạn,
-- tạo dataset tên `floodit` (vùng US), rồi chạy LẦN LƯỢT từng khối.
-- Khối 0 để XEM dữ liệu trước: tên sự kiện và tên tham số (event_params)
-- có thể khác dự đoán của mình -> chỉnh lại các khối sau cho khớp.
-- =====================================================================


-- =====================================================================
-- 0. HIỂU DỮ LIỆU
-- =====================================================================

-- 0.1 Khoảng ngày, số dòng, số người chơi
SELECT MIN(event_date) AS ngay_dau, MAX(event_date) AS ngay_cuoi,
       COUNT(*) AS so_dong, COUNT(DISTINCT user_pseudo_id) AS so_nguoi
FROM `firebase-public-project.analytics_153293282.events_*`;

-- 0.2 Có những sự kiện nào, mỗi sự kiện bao nhiêu dòng / người
SELECT event_name, COUNT(*) AS so_dong, COUNT(DISTINCT user_pseudo_id) AS so_nguoi
FROM `firebase-public-project.analytics_153293282.events_*`
GROUP BY event_name ORDER BY so_dong DESC;

-- 0.3 Mỗi sự kiện liên quan tới level có những tham số gì
--     (tìm tên tham số chứa level, điểm, số bước... để dùng ở khối 1)
SELECT event_name, p.key,
       COUNTIF(p.value.string_value IS NOT NULL) AS co_string,
       COUNTIF(p.value.int_value    IS NOT NULL) AS co_int,
       COUNTIF(p.value.double_value IS NOT NULL) AS co_double,
       ANY_VALUE(COALESCE(p.value.string_value,
                          CAST(p.value.int_value AS STRING),
                          CAST(p.value.double_value AS STRING))) AS vi_du
FROM `firebase-public-project.analytics_153293282.events_*`, UNNEST(event_params) p
WHERE event_name LIKE 'level%' OR event_name IN ('use_extra_steps','spend_virtual_currency','ad_reward','post_score')
GROUP BY 1, 2 ORDER BY 1, 2;

-- 0.4 Tham số của level_start / level_retry / level_up (chế độ chơi theo level)
SELECT event_name, p.key, COUNT(*) AS so_dong,
       ANY_VALUE(COALESCE(p.value.string_value, CAST(p.value.int_value AS STRING),
                          CAST(p.value.double_value AS STRING))) AS vi_du
FROM `firebase-public-project.analytics_153293282.events_*`, UNNEST(event_params) p
WHERE event_name IN ('level_start','level_retry','level_up','use_extra_steps','spend_virtual_currency')
GROUP BY 1, 2 ORDER BY 1, 2;

-- 0.5 Sau level_retry thì sự kiện tiếp theo là gì
--     (để biết retry có tự sinh thêm level_start không -> tránh đếm 1 lượt thành 2)
WITH lv AS (
  SELECT user_pseudo_id, event_timestamp, event_name,
         LEAD(event_name) OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS next_event
  FROM `firebase-public-project.analytics_153293282.events_*`
  WHERE event_name IN ('level_start','level_end','level_complete','level_fail','level_reset','level_retry','level_up')
)
SELECT event_name, next_event, COUNT(*) AS so_lan
FROM lv GROUP BY 1, 2 ORDER BY 1, so_lan DESC;

-- 0.6 Kiểm tra dòng trùng (cùng người, cùng sự kiện, cùng thời điểm)
SELECT COUNT(*) AS tong_dong,
       COUNT(DISTINCT CONCAT(user_pseudo_id, event_name, CAST(event_timestamp AS STRING))) AS dong_khong_trung
FROM `firebase-public-project.analytics_153293282.events_*`;


-- =====================================================================
-- 1. BẢNG GỌN ĐỂ PHÂN TÍCH (lọc trùng, chỉ giữ cột cần dùng)
--    Sửa tên tham số theo kết quả khối 0.3 nếu khác.
-- =====================================================================
CREATE OR REPLACE TABLE floodit.events AS
SELECT
  user_pseudo_id,
  PARSE_DATE('%Y%m%d', event_date)                     AS event_date,
  TIMESTAMP_MICROS(event_timestamp)                    AS event_ts,
  event_name,
  DATE(TIMESTAMP_MICROS(user_first_touch_timestamp))   AS install_date,
  platform,
  geo.country                                          AS country,
  app_info.version                                     AS app_version,
  (SELECT value.int_value    FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
  -- level: lúc lưu dạng số nguyên, lúc dạng số thực, lúc chỉ có chữ 'level_20' -> gộp lại
  COALESCE(
    (SELECT COALESCE(value.int_value, CAST(value.double_value AS INT64))
       FROM UNNEST(event_params) WHERE key = 'level'),
    (SELECT SAFE_CAST(REGEXP_EXTRACT(value.string_value, r'(\d+)') AS INT64)
       FROM UNNEST(event_params) WHERE key = 'level_name'))                          AS level,
  (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'board')         AS board,
  (SELECT COALESCE(value.int_value, CAST(value.double_value AS INT64))
     FROM UNNEST(event_params) WHERE key = 'value')                                 AS value,   -- ý nghĩa cần kiểm tra (có thể là số bước)
  (SELECT COALESCE(value.int_value, CAST(value.double_value AS INT64))
     FROM UNNEST(event_params) WHERE key = 'score')                                 AS score
FROM `firebase-public-project.analytics_153293282.events_*`
WHERE TRUE
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY user_pseudo_id, event_name, event_timestamp ORDER BY event_timestamp) = 1;

-- 1.1 Bảng người chơi: ngày cài, nền tảng, quốc gia, ngày hoạt động cuối
CREATE OR REPLACE TABLE floodit.users AS
SELECT user_pseudo_id,
       MIN(install_date)     AS install_date,
       ANY_VALUE(platform)   AS platform,
       ANY_VALUE(country)    AS country,
       MAX(event_date)       AS last_active_date
FROM floodit.events
WHERE install_date IS NOT NULL
GROUP BY user_pseudo_id;


-- =====================================================================
-- 2. KIỂM TRA CHẤT LƯỢNG DỮ LIỆU
-- =====================================================================

-- 2.1 Số dòng và số người theo ngày: tìm ngày bị hụt dữ liệu bất thường
--     (giống ngày 13/08 ở bài cũ: mọi chỉ số cùng tụt một lúc)
SELECT event_date, COUNT(*) AS so_dong, COUNT(DISTINCT user_pseudo_id) AS so_nguoi
FROM floodit.events GROUP BY 1 ORDER BY 1;

--     KẾT QUẢ: mỗi ngày đúng ~50,000 dòng -> dữ liệu là MẪU, bị cắt 50k sự kiện/ngày.
--     => Số tuyệt đối (DAU, số lượt chơi theo ngày) KHÔNG phản ánh quy mô thật;
--        chỉ dùng TỶ LỆ (win rate, % qua màn...). Hành trình mỗi người có thể
--        thiếu sự kiện -> retention / rời đi có thể bị tính thấp hơn thực tế.

-- 2.1b Ngày nào có nhiều người chơi bất thường (~1,200 thay vì ~450): người mới hay người cũ?
SELECT e.event_date,
       COUNT(DISTINCT e.user_pseudo_id) AS so_nguoi,
       COUNT(DISTINCT IF(u.install_date = e.event_date, e.user_pseudo_id, NULL)) AS nguoi_moi,
       ROUND(COUNT(*) / COUNT(DISTINCT e.user_pseudo_id), 1) AS su_kien_moi_nguoi
FROM floodit.events e JOIN floodit.users u USING (user_pseudo_id)
GROUP BY 1 ORDER BY 1;

-- 2.2 Người chơi không có ngày cài / ngày cài nằm ngoài khoảng dữ liệu
SELECT COUNTIF(install_date IS NULL) AS khong_co_ngay_cai,
       COUNTIF(install_date < (SELECT MIN(event_date) FROM floodit.events)) AS cai_truoc_khoang_du_lieu
FROM (SELECT user_pseudo_id, MIN(install_date) AS install_date FROM floodit.events GROUP BY 1);


-- =====================================================================
-- 3. TRANG 1 · SỨC KHỎE CHUNG
-- =====================================================================

-- 3.1 Theo ngày: người chơi mới, DAU, lượt chơi, lượt thắng
SELECT d.event_date,
       COUNT(DISTINCT IF(u.install_date = d.event_date, d.user_pseudo_id, NULL))          AS new_users,
       COUNT(DISTINCT IF(d.event_name = 'user_engagement', d.user_pseudo_id, NULL))      AS dau,
       COUNTIF(d.event_name = 'level_start')                                              AS luot_choi_level,
       COUNTIF(d.event_name = 'level_start_quickplay')                                    AS luot_choi_quickplay,
       COUNTIF(d.event_name = 'level_complete')                                           AS luot_thang_level
FROM floodit.events d JOIN floodit.users u USING (user_pseudo_id)
GROUP BY 1 ORDER BY 1;

-- 3.2 Retention D1 / D3 / D7 theo cohort ngày cài (chỉ cohort đã đủ 7 ngày)
WITH active AS (
  SELECT DISTINCT user_pseudo_id, event_date
  FROM floodit.events WHERE event_name = 'user_engagement'
)
SELECT u.install_date,
       COUNT(DISTINCT u.user_pseudo_id) AS cohort_size,
       ROUND(COUNT(DISTINCT IF(DATE_DIFF(a.event_date, u.install_date, DAY) = 1, u.user_pseudo_id, NULL))
             / COUNT(DISTINCT u.user_pseudo_id) * 100, 2) AS d1_pct,
       ROUND(COUNT(DISTINCT IF(DATE_DIFF(a.event_date, u.install_date, DAY) = 3, u.user_pseudo_id, NULL))
             / COUNT(DISTINCT u.user_pseudo_id) * 100, 2) AS d3_pct,
       ROUND(COUNT(DISTINCT IF(DATE_DIFF(a.event_date, u.install_date, DAY) = 7, u.user_pseudo_id, NULL))
             / COUNT(DISTINCT u.user_pseudo_id) * 100, 2) AS d7_pct
FROM floodit.users u
LEFT JOIN active a USING (user_pseudo_id)
WHERE u.install_date BETWEEN (SELECT MIN(event_date) FROM floodit.events)
                         AND DATE_SUB((SELECT MAX(event_date) FROM floodit.events), INTERVAL 7 DAY)
GROUP BY 1 ORDER BY 1;


-- =====================================================================
-- 4. BẢNG NGƯỜI CHƠI × LEVEL
--    Game có 2 chế độ:
--      - Chơi theo level (level_start, level_complete...): có số level
--        -> dùng cho phân tích độ khó và hành trình (giống bài cũ)
--      - Quickplay (..._quickplay): không có level, chỉ có cỡ bàn (board)
--        -> phân tích riêng ở khối 4.1
--    Khối 0.5 cho thấy THỨ TỰ sự kiện không sạch (start -> start,
--    complete -> complete, retry -> complete mà không có start...),
--    nên KHÔNG ghép từng lượt theo thứ tự, mà ĐẾM sự kiện của mỗi người
--    ở mỗi level. Số lần thử = level_start + level_retry
--    (bấm "chơi lại" ở màn thua phần lớn không sinh thêm level_start).
-- =====================================================================
CREATE OR REPLACE TABLE floodit.user_level AS
WITH ev AS (
  SELECT user_pseudo_id, level, event_name, event_ts
  FROM floodit.events
  WHERE level IS NOT NULL
    AND event_name IN ('level_start','level_retry','level_complete','level_fail','level_reset')
),
ev2 AS (   -- đánh dấu retry ngay sau đó có level_start cùng level -> cùng 1 lần thử
  SELECT *,
         COALESCE(event_name = 'level_retry'
                  AND LEAD(event_name) OVER w = 'level_start'
                  AND LEAD(level)      OVER w = level, FALSE) AS retry_trung
  FROM ev
  WINDOW w AS (PARTITION BY user_pseudo_id ORDER BY event_ts)
),
fw AS (
  SELECT user_pseudo_id, level, MIN(event_ts) AS first_win_ts
  FROM ev WHERE event_name = 'level_complete' GROUP BY 1, 2
)
SELECT ev.user_pseudo_id, ev.level,
       COUNTIF(event_name = 'level_start'
               OR (event_name = 'level_retry' AND NOT retry_trung)) AS n_try,
       COUNTIF(event_name = 'level_complete')               AS n_win,
       COUNTIF(event_name = 'level_fail')                   AS n_fail,
       COUNTIF(event_name = 'level_reset')                  AS n_reset,
       MIN(ev.event_ts)                                     AS first_ts,
       ANY_VALUE(fw.first_win_ts)                           AS first_win_ts,
       -- số lần thử cho tới lần thắng đầu tiên (NULL nếu chưa thắng)
       IF(ANY_VALUE(fw.first_win_ts) IS NULL, NULL,
          GREATEST(1, COUNTIF((event_name = 'level_start'
                               OR (event_name = 'level_retry' AND NOT retry_trung))
                              AND ev.event_ts <= fw.first_win_ts))) AS tries_to_first_win
FROM ev2 AS ev LEFT JOIN fw USING (user_pseudo_id, level)
GROUP BY ev.user_pseudo_id, ev.level;

-- 4.0 Kiểm tra nhanh: tổng số thử / thắng / thua / reset
SELECT SUM(n_try) AS thu, SUM(n_win) AS thang, SUM(n_fail) AS thua, SUM(n_reset) AS choi_lai,
       SUM(n_try) - SUM(n_win) - SUM(n_fail) - SUM(n_reset) AS bo_giua_chung_uoc_tinh,
       ROUND((SUM(n_try) - SUM(n_win) - SUM(n_fail) - SUM(n_reset)) / SUM(n_try) * 100, 1) AS bo_giua_chung_pct
FROM floodit.user_level;


-- 4.1 Quickplay: độ khó theo cỡ bàn (board)
SELECT board,
       COUNTIF(event_name = 'level_start_quickplay')    AS so_luot,
       COUNTIF(event_name = 'level_complete_quickplay') AS so_thang,
       COUNTIF(event_name = 'level_fail_quickplay')     AS so_thua,
       COUNTIF(event_name = 'level_reset_quickplay')    AS so_choi_lai,
       ROUND(COUNTIF(event_name = 'level_complete_quickplay')
             / NULLIF(COUNTIF(event_name = 'level_start_quickplay'), 0) * 100, 2) AS win_rate_pct
FROM floodit.events
WHERE event_name LIKE 'level_%_quickplay'
GROUP BY board ORDER BY board;


-- =====================================================================
-- 5. TRANG 3 · LEVEL NÀO KHÓ
-- =====================================================================
SELECT level,
       COUNT(*)                                                     AS so_nguoi_choi,
       SUM(n_try)                                                   AS so_lan_thu,
       ROUND(SUM(n_win) / NULLIF(SUM(n_win) + SUM(n_fail), 0) * 100, 2) AS win_rate_pct,   -- thắng / (thắng + thua): chỉ số CHÍNH
       ROUND(SUM(n_win) / NULLIF(SUM(n_try), 0) * 100, 2)          AS thang_tren_lan_thu_pct, -- tham khảo, bị kéo thấp bởi lượt bỏ dở
       ROUND(COUNTIF(n_win > 0) / COUNT(*) * 100, 2)                AS ty_le_qua_man_pct, -- % người đã qua
       ROUND(COUNTIF(tries_to_first_win = 1)
             / NULLIF(COUNTIF(n_win > 0), 0) * 100, 2)             AS qua_ngay_lan_dau_pct,
       ROUND(AVG(tries_to_first_win), 2)                            AS so_lan_thu_tb_de_qua,
       ROUND(SUM(n_reset) / NULLIF(SUM(n_try), 0) * 100, 2)         AS reset_pct
FROM floodit.user_level
GROUP BY level
HAVING so_nguoi_choi >= 30                -- bỏ level quá ít người, số dễ nhiễu
ORDER BY level;


-- =====================================================================
-- 6. TRANG 2 · NGƯỜI CHƠI RỜI ĐI Ở ĐÂU
--    "Rời đi" = không hoạt động trong 7 ngày cuối của dữ liệu.
--    Level dừng lại = level cao nhất người đó từng chơi.
--    CHỈ lấy người cài game trong khoảng dữ liệu (từ 12/06/2018):
--    9,086 / 15,175 người đã cài từ trước, hành trình của họ không bắt đầu
--    từ level 1 trong dữ liệu nên không dùng cho funnel.
--    "Tới level L" = level cao nhất >= L (dữ liệu bị lấy mẫu, có người
--    thiếu sự kiện ở level trước nhưng vẫn có ở level sau).
-- =====================================================================
WITH new_users AS (
  SELECT user_pseudo_id FROM floodit.users
  WHERE install_date >= (SELECT MIN(event_date) FROM floodit.events)
),
max_lv AS (
  SELECT user_pseudo_id,
         MAX(level) AS max_level,
         ARRAY_AGG(n_win > 0 ORDER BY level DESC LIMIT 1)[OFFSET(0)] AS da_qua_level_cuoi
  FROM floodit.user_level
  WHERE user_pseudo_id IN (SELECT user_pseudo_id FROM new_users)
  GROUP BY 1
),
churned AS (
  SELECT user_pseudo_id FROM floodit.users
  WHERE last_active_date <= DATE_SUB((SELECT MAX(event_date) FROM floodit.events), INTERVAL 7 DAY)
),
reach AS (
  SELECT lv.level, COUNTIF(m.max_level >= lv.level) AS so_nguoi_toi
  FROM (SELECT DISTINCT level FROM floodit.user_level) lv CROSS JOIN max_lv m
  GROUP BY lv.level
)
SELECT r.level,
       r.so_nguoi_toi,
       ROUND(r.so_nguoi_toi / FIRST_VALUE(r.so_nguoi_toi) OVER (ORDER BY r.level) * 100, 2) AS pct_con_lai,
       COUNT(c.user_pseudo_id)                                         AS so_nguoi_dung_lai,
       ROUND(COUNT(c.user_pseudo_id) / r.so_nguoi_toi * 100, 2)        AS drop_rate_pct,
       COUNTIF(c.user_pseudo_id IS NOT NULL AND m.da_qua_level_cuoi)     AS roi_sau_khi_qua,
       COUNTIF(c.user_pseudo_id IS NOT NULL AND NOT m.da_qua_level_cuoi) AS roi_khi_chua_qua
FROM reach r
LEFT JOIN max_lv m  ON m.max_level = r.level
LEFT JOIN churned c ON c.user_pseudo_id = m.user_pseudo_id
GROUP BY r.level, r.so_nguoi_toi
HAVING r.so_nguoi_toi >= 30
ORDER BY r.level;

-- 6.1 Rời đi theo ngày tuổi: người chơi thường bỏ game sau bao nhiêu ngày
SELECT DATE_DIFF(last_active_date, install_date, DAY) AS so_ngay_choi,
       COUNT(*) AS so_nguoi
FROM floodit.users
WHERE last_active_date <= DATE_SUB((SELECT MAX(event_date) FROM floodit.events), INTERVAL 7 DAY)
GROUP BY 1 ORDER BY 1;


-- =====================================================================
-- 7. TRANG 4 · KHÓ CÓ ĐÁNG KHÔNG
--    use_extra_steps / spend_virtual_currency (mua thêm bước) ~ booster ở bài cũ
--    ad_reward (xem quảng cáo có thưởng, nhiều lần để lấy thêm bước)
--    Các sự kiện này KHÔNG có số level -> gắn vào sự kiện level gần nhất trước nó.
--    Lưu ý: có thể dính cả quickplay; giới hạn trong 30 phút sau sự kiện level.
-- =====================================================================
WITH help AS (
  SELECT user_pseudo_id, event_ts, event_name
  FROM floodit.events
  WHERE event_name IN ('use_extra_steps','spend_virtual_currency','ad_reward')
),
lv AS (
  SELECT user_pseudo_id, event_ts, level
  FROM floodit.events
  WHERE level IS NOT NULL
    AND event_name IN ('level_start','level_retry','level_complete','level_fail','level_reset')
),
help_lv AS (
  SELECT h.event_name, l.level
  FROM help h
  JOIN lv l
    ON l.user_pseudo_id = h.user_pseudo_id
   AND l.event_ts <= h.event_ts
   AND l.event_ts >= TIMESTAMP_SUB(h.event_ts, INTERVAL 30 MINUTE)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY h.user_pseudo_id, h.event_ts, h.event_name
                             ORDER BY l.event_ts DESC) = 1
),
lvl AS (
  SELECT level, SUM(n_try) AS so_lan_thu,
         ROUND(SUM(n_win) / NULLIF(SUM(n_win) + SUM(n_fail), 0) * 100, 2) AS win_rate_pct
  FROM floodit.user_level WHERE level BETWEEN 1 AND 30
  GROUP BY 1 HAVING COUNT(*) >= 30
)
SELECT lvl.level, lvl.so_lan_thu, lvl.win_rate_pct,
       ROUND(COUNTIF(h.event_name = 'use_extra_steps')        / NULLIF(lvl.so_lan_thu, 0) * 100, 2) AS extra_steps_moi_100_lan,
       ROUND(COUNTIF(h.event_name = 'spend_virtual_currency') / NULLIF(lvl.so_lan_thu, 0) * 100, 2) AS tieu_tien_ao_moi_100_lan,
       ROUND(COUNTIF(h.event_name = 'ad_reward')              / NULLIF(lvl.so_lan_thu, 0) * 100, 2) AS ad_reward_moi_100_lan
FROM lvl LEFT JOIN help_lv h USING (level)
GROUP BY lvl.level, lvl.so_lan_thu, lvl.win_rate_pct
ORDER BY lvl.level;

-- 7.1 Ghép kết quả khối 5, 6, 7 theo level (trong Python / Looker) để trả lời:
--     level khó có làm người chơi dùng thêm bước / xem ads nhiều hơn,
--     hay chỉ làm họ bỏ game?


-- =====================================================================
-- 8. XUẤT DỮ LIỆU CHO LOOKER STUDIO
--    Trong BigQuery: chạy từng khối 3.1, 3.2, 4.1, 5, 6, 7 -> "Save results"
--    -> CSV, hoặc kết nối Looker Studio thẳng với bảng floodit.*
-- =====================================================================
