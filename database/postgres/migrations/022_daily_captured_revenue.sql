create materialized view daily_captured_revenue as
select
    r.operator_id,
    p.created_utc::date as revenue_date,
    sum(p.amount) as captured_amount,
    count(*) as captured_payments
from payments p
join tickets t on t.id = p.ticket_id
join trips tr on tr.id = t.trip_id
join routes r on r.id = tr.route_id
where p.status = 'Captured'
group by r.operator_id, p.created_utc::date
with no data;

create unique index daily_captured_revenue_key
    on daily_captured_revenue (operator_id, revenue_date);

-- Run explicitly when the source data should become visible:
-- refresh materialized view daily_captured_revenue;
