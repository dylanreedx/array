import { mailer } from '@roast/mail';

/** "Your coffee is on its way": sent when an order is placed. */
export async function sendOrderEmail(order: { id: string; email: string }) {
  await mailer.send({ to: order.email, template: 'order-placed', data: { id: order.id } });
}
