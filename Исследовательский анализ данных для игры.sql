/* Проект «Секреты Тёмнолесья»
 * Цель проекта: изучить влияние характеристик игроков и их игровых персонажей 
 * на покупку внутриигровой валюты «райские лепестки», а также оценить 
 * активность игроков при совершении внутриигровых покупок
 * 
 * Автор: Туровская Мария Сергеевна
 * Дата: 16.04.2026
*/

-- Часть 1. Исследовательский анализ данных
-- Задача 1. Исследование доли платящих игроков

-- 1.1. Доля платящих пользователей по всем данным:
SELECT
    COUNT(payer) AS total_users, -- общее количество игроков
    SUM(payer) AS total_payers, -- количество платящих (сумма единичек)
    AVG(payer) AS payers_share -- доля платящих (среднее значение)
FROM fantasy.users
WHERE payer=1 OR payer =0;

-- 1.2. Доля платящих пользователей в разрезе расы персонажа:
SELECT
	u.race_id,
	r.race,
	SUM(CASE WHEN u.payer = 1 THEN 1 ELSE 0 END) AS paying_players,
	COUNT(u.id) AS total_registered,
	ROUND(
        SUM(CASE WHEN u.payer = 1 THEN 1 ELSE 0 END) * 1.0
        / COUNT(u.id) * 100, 2
    ) AS percent_of_paying_customers
FROM
	fantasy.users u
JOIN fantasy.race r ON
	u.race_id = r.race_id
GROUP BY
	u.race_id,
	r.race
ORDER BY
	percent_of_paying_customers DESC;

-- Задача 2. Исследование внутриигровых покупок
-- 2.1. Статистические показатели по полю amount:
SELECT
	count(amount) AS number_of_transactions,
	round(sum(amount)::NUMERIC, 2) AS amount_of_transactions,
	round(min(amount)::NUMERIC, 2) AS min_amount,
	round(max(amount)::NUMERIC, 2) AS max_amount,
	round(avg(amount)::NUMERIC, 2) AS average_amount,
	PERCENTILE_DISC(0.5) WITHIN GROUP (
	ORDER BY amount) AS median,
	round(stddev(amount)::NUMERIC, 2) AS standard_deviation
FROM
	fantasy.events
WHERE
	amount>0;

-- 2.2: Аномальные нулевые покупки:
SELECT
	(
	SELECT
		count(transaction_id)
	FROM
		fantasy.events
	WHERE
		amount = 0) AS number_of_zero_transactions,
	count(transaction_id) AS total_number_of_transactions,
	((
	SELECT
		count(transaction_id)
	FROM
		fantasy.events
	WHERE
		amount = 0)* 1.0 /(count(transaction_id))) AS share_of_zero_transactions
FROM
	fantasy.events


-- 2.3: Популярные эпические предметы:
SELECT
	i.game_items,
	COUNT(e.transaction_id) AS number_of_transactions,
	COUNT(e.transaction_id) * 1.0 / SUM(COUNT(e.transaction_id)) OVER() AS share_of_total,
	COUNT(DISTINCT e.id) AS buyers_of_item,
	COUNT(DISTINCT e.id) * 1.0 / (
	SELECT
		COUNT(DISTINCT id)
	FROM
		fantasy.events
	WHERE
		amount > 0
    ) AS share_of_players
FROM
	fantasy.events AS e
INNER JOIN fantasy.items AS i ON
	e.item_code = i.item_code
WHERE
	e.amount > 0
GROUP BY
	i.game_items
ORDER BY
	buyers_of_item DESC;


-- Часть 2. Решение ad hoc-задачbи
-- Задача: Зависимость активности игроков от расы персонажа:
WITH 
total_users AS (
    SELECT
        race_id,
        COUNT(DISTINCT id) AS total_reg_users
    FROM fantasy.users
    GROUP BY race_id
),
player_purchases AS (
    SELECT
        u.race_id,
        u.id AS user_id,
        u.payer,
        COUNT(e.transaction_id) AS user_transactions,
        SUM(e.amount) AS user_total_spent
    FROM fantasy.users u
    JOIN fantasy.events e ON u.id = e.id
    WHERE e.amount > 0
    GROUP BY u.race_id, u.id, u.payer
),
race_purchase_stats AS (
    SELECT
        race_id,
        COUNT(DISTINCT user_id) AS buyers_count,
        SUM(CASE WHEN payer = 1 THEN 1 ELSE 0 END) AS paying_status_count,
        SUM(user_transactions) AS total_race_transactions,
        SUM(user_total_spent) AS total_race_spent
    FROM player_purchases
    GROUP BY race_id
)
SELECT
    tu.race_id,
    r.race,                                                                         
    tu.total_reg_users,
    rps.buyers_count,
    rps.buyers_count * 1.0 / tu.total_reg_users AS share_of_buyers,
    rps.paying_status_count * 1.0 / rps.buyers_count AS paying_share_among_buyers,
    rps.total_race_transactions * 1.0 / rps.buyers_count AS avg_transactions_per_buyer,
    rps.total_race_spent * 1.0 / rps.total_race_transactions AS avg_purchase_price,
    rps.total_race_spent * 1.0 / rps.buyers_count AS avg_total_spent_per_buyer
FROM total_users tu
LEFT JOIN race_purchase_stats rps ON tu.race_id = rps.race_id
LEFT JOIN fantasy.race r ON tu.race_id = r.race_id                                      
ORDER BY avg_total_spent_per_buyer DESC;
