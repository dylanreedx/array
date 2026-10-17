import { router } from '@roast/http';
import { sendOrderEmail } from '../emails/order';

export const orders = router().post('/', async (req) => {
  const order = await req.json();
  await sendOrderEmail(order);
  return { id: order.id, status: 'placed' };
});
