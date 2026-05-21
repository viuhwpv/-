/* Проект «Разработка витрины и решение ad-hoc задач»
 * Цель проекта: подготовка витрины данных маркетплейса «ВсёТут»
 * и решение четырех ad hoc задач на её основе
 * 
 * Автор: Туровская Мария Сергеевна 
 * Дата: 29.04.2026
*/



/* Часть 1. Разработка витрины данных
 * Напишите ниже запрос для создания витрины данных
*/
--составление витрины данных по заказам, которые были доставлены или отменены
--и ограниченная по топ-3 регионам продаж 
WITH top_3_regions AS (
    -- 1) Определяем ТОП-3 региона динамически
    SELECT region
    FROM ds_ecom.users u
    JOIN ds_ecom.orders o ON u.buyer_id = o.buyer_id
    GROUP BY region
    ORDER BY COUNT(order_id) DESC
    LIMIT 3
),
order_prices_cleaned AS (
    -- 2, 3, 6, 8) Считаем стоимость заказа (цена + доставка) и флаги ДО джоина к юзерам
    -- Это убирает дублирование при расчете средних чеков
    SELECT 
        oi.order_id,
        SUM(oi.price + oi.freight_value) AS full_order_cost,
        MAX(CASE WHEN op.payment_type = 'промокод' THEN 1 ELSE 0 END) AS has_promo,
        MAX(CASE WHEN op.payment_installments > 1 THEN 1 ELSE 0 END) AS has_installment
    FROM ds_ecom.order_items oi
    LEFT JOIN ds_ecom.order_payments op ON oi.order_id = op.order_id
    GROUP BY oi.order_id
),
first_payment_type AS (
    -- 7) Определяем тип САМОГО ПЕРВОГО платежа (payment_sequential = 1)
    SELECT DISTINCT ON (order_id)
        order_id,
        payment_type
    FROM ds_ecom.order_payments
    ORDER BY order_id, payment_sequential ASC
),
orders_extended AS (
    -- Собираем все данные по заказам в одну кучу с учетом регионов
    SELECT 
        o.order_id,
        o.buyer_id,
        u.user_id,
        u.region,
        o.order_status,
        o.order_purchase_ts,
        -- 5) Исправляем рейтинг (делим на 10, если > 5)
        CASE 
            WHEN r.review_score > 5 THEN r.review_score / 10.0 
            ELSE r.review_score 
        END AS corrected_score,
        r.review_id,
        opc.full_order_cost,
        opc.has_promo,
        opc.has_installment,
        fpt.payment_type AS first_pay_method
    FROM ds_ecom.orders o
    JOIN ds_ecom.users u ON o.buyer_id = u.buyer_id
    LEFT JOIN ds_ecom.order_reviews r ON o.order_id = r.order_id
    LEFT JOIN order_prices_cleaned opc ON o.order_id = opc.order_id
    LEFT JOIN first_payment_type fpt ON o.order_id = fpt.order_id
    WHERE u.region IN (SELECT region FROM top_3_regions)
      AND o.order_status IN ('Доставлено', 'Отменено')
),
final_user_stats AS (
    -- 4) Группируем одновременно по user_id и region
    SELECT 
        user_id,
        region,
        MIN(order_purchase_ts) AS first_order_ts,
        MAX(order_purchase_ts) AS last_order_ts,
        -- Считаем разницу в днях для lifetime
        EXTRACT(DAY FROM (MAX(order_purchase_ts) - MIN(order_purchase_ts))) AS lifetime,
        COUNT(order_id) AS total_orders,
        AVG(corrected_score) AS avg_order_rating,
        COUNT(review_id) AS num_orders_with_rating,
        COUNT(CASE WHEN order_status = 'Отменено' THEN 1 END) AS num_canceled_orders,
        -- Агрегаты по стоимостям (только для Доставлено)
        SUM(CASE WHEN order_status = 'Доставлено' THEN full_order_cost END) AS total_order_costs,
        AVG(CASE WHEN order_status = 'Доставлено' THEN full_order_cost END) AS avg_order_cost,
        -- Агрегаты по платежам
        SUM(has_installment) AS num_installment_orders,
        SUM(has_promo) AS num_orders_with_promo,
        -- Бинарные признаки
        MAX(CASE WHEN first_pay_method = 'денежный перевод' THEN 1 ELSE 0 END) AS used_money_transfer,
        MAX(has_installment) AS used_installments,
        MAX(CASE WHEN order_status = 'Отменено' THEN 1 ELSE 0 END) AS used_cancel
    FROM orders_extended
    GROUP BY user_id, region
)
-- Вывод витрины с расчетом доли отмен
SELECT 
    *,
    ROUND(num_canceled_orders * 1.0 / NULLIF(total_orders, 0), 2) AS canceled_orders_ratio
FROM final_user_stats;


/* Часть 2. Решение ad hoc задач
 * Для каждой задачи напишите отдельный запрос.
 * После каждой задачи оставьте краткий комментарий с выводами по полученным результатам.
*/

/* Задача 1. Сегментация пользователей 
 * Разделите пользователей на группы по количеству совершённых ими заказов.
 * Подсчитайте для каждой группы общее количество пользователей,
 * среднее количество заказов, среднюю стоимость заказа.
 * 
 * Выделите такие сегменты:
 * - 1 заказ — сегмент 1 заказ
 * - от 2 до 5 заказов — сегмент 2-5 заказов
 * - от 6 до 10 заказов — сегмент 6-10 заказов
 * - 11 и более заказов — сегмент 11 и более заказов
*/

WITH user_segments AS (
    SELECT
        *,
        CASE  
            WHEN total_orders = 1 THEN '1 заказ'
            WHEN total_orders BETWEEN 2 AND 5 THEN '2—5 заказов'
            WHEN total_orders BETWEEN 6 AND 10 THEN '6–10 заказов'
            WHEN total_orders >= 11 THEN '11 и более заказов'
        END AS segment
    FROM ds_ecom.product_user_features
)
SELECT
    segment,
    COUNT(user_id) AS number_of_users,
    ROUND(AVG(total_orders), 2) AS avg_orders_per_user,
    -- Корректировка 1: Отношение суммы всех покупок к их количеству в сегменте
    ROUND(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_purchase_cost
FROM user_segments
GROUP BY segment
ORDER BY number_of_users DESC;

/* Напишите краткий комментарий с выводами по результатам задачи 1.
 * 
*/По 1 разу купили 60468 раз на сумму 3,305 рубля, от 2-5 раз было заказано 1934 раза на сумму 3058 рублей, 
от 6 и более раз куплено заказов было сделано 5 раз 2769 рублей. Больше 11 раз делали заказы только 1 раз на сумму 1244 руб. 
Таким образом большинство пользователей покупает заказы на платформе 1 раз
на относительно большую сумму, что может указывать на том, что пользватели один раз заходят на платформу, покупают сразу 
много товаров и не возвращаются к ней. таким образом нужно прроработать постоянное возвращение пользователя на платформу, возможно 
добавить какие то услуги чтоб польззователь мог парралельно заказывать товары



/* Задача 2. Ранжирование пользователей 
 * Отсортируйте пользователей, сделавших 3 заказа и более, по убыванию среднего чека покупки.  
 * Выведите 15 пользователей с самым большим средним чеком среди указанной группы.
*/

SELECT 
    user_id,
    total_orders,
    avg_order_cost,
    DENSE_RANK() OVER (ORDER BY avg_order_cost DESC) AS cost_rank
FROM ds_ecom.product_user_features
WHERE total_orders >= 3
ORDER BY cost_rank ASC
LIMIT 15;

/* Напишите краткий комментарий с выводами по результатам задачи 2.
 * 
*/
Самый высокий средний чек заказа 14716.67 руб у пользователя 0a0a92112bd4c708ca5fde585afaa872
у 15 в рейтинге средний чек заказа составляет 5526 руб. Разброс между топ-1 и топ-2 составляет полутора тысяч 


/* Задача 3. Статистика по регионам. 
 * Для каждого региона подсчитайте:
 * - общее число клиентов и заказов;
 * - среднюю стоимость одного заказа;
 * - долю заказов, которые были куплены в рассрочку;
 * - долю заказов, которые были куплены с использованием промокодов;
 * - долю пользователей, совершивших отмену заказа хотя бы один раз.
*/

SELECT
    region,
    COUNT(user_id) AS num_of_customers,
    SUM(total_orders) AS total_orders,
    -- Корректировка: Отношение суммы заказов к их общему количеству
    ROUND(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_order_cost,
    ROUND(SUM(num_installment_orders * 1.0) / SUM(total_orders), 4) AS installments_ratio,
    ROUND(SUM(num_orders_with_promo * 1.0) / SUM(total_orders), 4) AS promo_ratio,
    -- Доля пользователей, отменивших хотя бы раз (среднее по флагу)
    ROUND(AVG(used_cancel), 4) AS users_with_cancel_ratio
FROM ds_ecom.product_user_features
GROUP BY region
ORDER BY total_orders DESC;

/* Напишите краткий комментарий с выводами по результатам задачи 3.
 * 
*/Выше всего чек и количество клиентов в регионе Москва, средний чек в 3 раза больше чем в Питере и Новосибирской области
Клиентов пользовавшихся  рассрочкой для оплаты заказов на 10 сотых выше в питере и новосибирской области чем в москве 
В питере и новосибирской области примерно одинаковое количество клиентов 


/* Задача 4. Активность пользователей по первому месяцу заказа в 2023 году
 * Разбейте пользователей на группы в зависимости от того, в какой месяц 2023 года они совершили первый заказ.
 * Для каждой группы посчитайте:
 * - общее количество клиентов, число заказов и среднюю стоимость одного заказа;
 * - средний рейтинг заказа;
 * - долю пользователей, использующих денежные переводы при оплате;
 * - среднюю продолжительность активности пользователя.
*/

SELECT
    DATE_TRUNC('month', first_order_ts) AS start_month,
    COUNT(user_id) AS total_customers,
    SUM(total_orders) AS total_orders,
    -- Средняя стоимость заказа
    ROUND(SUM(total_order_costs) / SUM(total_orders), 2) AS avg_order_cost,
    -- Средний рейтинг 
    ROUND(AVG(avg_order_rating), 2) AS avg_rating,
    -- Доля пользователей (делим на клиентов, а не на заказы)
    ROUND(SUM(used_money_transfer * 1.0) / COUNT(user_id), 4) AS money_transfer_user_ratio,
    AVG(lifetime) AS avg_lifetime
FROM ds_ecom.product_user_features
WHERE first_order_ts >= '2023-01-01' AND first_order_ts < '2024-01-01'
GROUP BY 1
ORDER BY 1 ASC;


/* Напишите краткий комментарий с выводами по результатам задачи 4.
 * Больше всего заказов было совершено в ноябре-4892, что связано с праздниками. меньше всего заказов было
 * совершено 1 января-499 штук. оплата переводом чаще всего было в 20% случаях стабильно в течение года. максимальная продолжительность 
 * активности пользователя была 12 дней 1 января. средний рейтинг стабильно высокий, что говорит о качестве продаваемого 
 * товара. количество пользователей стабильно увеличивается с наступлением периода праздников в декабре-январе. 
 * в начале года продолжительность жизни пользователя выше чем у тех кто приходит только на праздниках
 * тк у них больше времени на повторные покупки






