import 'package:flutter_test/flutter_test.dart';
import 'package:az_express/models/decline_order_result.dart';
void main() {
  test('normal refusal', () { final r=DeclineOrderResult.fromData({'success':true,'replay':false}); expect(r.replay,false); expect(r.recoveryPending,false); });
  test('replay and recovery pending', () { final r=DeclineOrderResult.fromData({'success':true,'replay':true,'recoveryPending':true}); expect(r.replay,true); expect(r.recoveryPending,true); });
  for(final data in [null, {}, {'success':false,'replay':false}, {'success':true}, {'success':true,'replay':false,'recoveryPending':'true'}]) {
    test('reject malformed $data', () => expect(()=>DeclineOrderResult.fromData(data),throwsFormatException));
  }
}
