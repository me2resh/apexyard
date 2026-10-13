import { addItem, listItems, type AddResult } from "../../../application/items";
import { isJsonRequest, problem } from "../../../infrastructure/problem";

export const dynamic = "force-dynamic";

type CreateItem = (input: unknown) => Promise<AddResult>;

export async function createItemResponse(request: Request, create: CreateItem): Promise<Response> {
  if (!isJsonRequest(request)) {
    return problem(415, "unsupported-media-type", "Unsupported media type");
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return problem(400, "invalid-json", "Invalid JSON");
  }
  try {
    const result = await create(body);
    if (!result.ok) {
      return problem(400, result.code, "Invalid item");
    }
    return Response.json({ item: result.item }, { status: 201 });
  } catch {
    return problem(500, "internal-error", "Internal error");
  }
}

export function POST(request: Request): Promise<Response> {
  return createItemResponse(request, addItem);
}

export async function listItemsResponse(list: typeof listItems): Promise<Response> {
  try {
    const found = await list();
    return Response.json({ items: found });
  } catch {
    return problem(500, "internal-error", "Internal error");
  }
}

export function GET(): Promise<Response> {
  return listItemsResponse(listItems);
}
